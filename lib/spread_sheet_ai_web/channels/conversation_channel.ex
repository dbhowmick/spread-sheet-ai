defmodule SpreadSheetAiWeb.ConversationChannel do
  @moduledoc """
  `conversation:<conversation_id>` (contract §7, docs/backend-plan.md §7.3):
  the chat of a shared conversation, its linked sheets and its viewers.

  The channel process is a Sagents subscriber of the conversation's agent.
  Agent events arrive as `{:agent, agent_id, event}` (sent to this process,
  not over PubSub) and become pushes through `SpreadSheetAiWeb.ConversationEvents`.

  - **No agent yet.** When no agent is running, the subscription is
    `:pending`. It is revived when the agent's presence join arrives on
    `"agent_server:presence"`. Another viewer's message can be stored before
    that, so a revival also pushes every stored message from the newest one
    this channel has sent onwards; the client replaces messages by id.
  - **Viewers.** The channel tracks its user as a conversation viewer on its
    own topic (`Coordinator.track_conversation_viewer/3`), which keeps an
    idle agent running while someone is watching, and turns presence diffs
    into `participants` pushes.
  - **App events** (`{:sheets_changed}`, `{:focus_sheet, id, reason}`) come
    from `SpreadSheetAi.Conversations.events_topic/1`.
  """

  use SpreadSheetAiWeb, :channel

  alias Sagents.Subscriber
  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Agents.{Chat, Coordinator}
  alias SpreadSheetAi.{Conversations, Sheets}
  alias SpreadSheetAiWeb.Api.Errors
  alias SpreadSheetAiWeb.{ConversationEvents, ConversationJSON, MessageJSON, Presence, SheetJSON}

  intercept ["presence_diff"]

  @impl Phoenix.Channel
  def join("conversation:" <> conversation_id, _params, socket) do
    case Conversations.get_conversation(scope(socket), conversation_id) do
      {:ok, conversation} ->
        # Subscribe before loading, so nothing stored in between is missed.
        :ok = Conversations.subscribe_events(conversation.id)
        :ok = Phoenix.PubSub.subscribe(SpreadSheetAi.PubSub, Subscriber.presence_topic())
        agent_id = Coordinator.conversation_agent_id(conversation.id)
        subs = Subscriber.subscribe_to_agent(%{}, agent_id, tagged: true)

        status = ConversationEvents.join_status(Chat.status(conversation.id))
        messages = Conversations.load_display_messages(scope(socket), conversation.id)

        reply = %{
          conversation: ConversationJSON.summary(conversation),
          messages: Enum.map(messages, &MessageJSON.message/1),
          sheets: Enum.map(Sheets.list_links(conversation.id), &ConversationJSON.linked_sheet/1),
          status: status
        }

        send(self(), :after_join)

        {:ok, reply,
         assign(socket,
           conversation_id: conversation.id,
           agent_id: agent_id,
           sagents_subs: subs,
           events: ConversationEvents.new(status),
           last_message_at: messages |> List.last() |> inserted_at()
         )}

      {:error, :not_found} ->
        {:error, Errors.from_business({:error, :not_found, "Conversation not found.", %{}})}
    end
  end

  @impl Phoenix.Channel
  def handle_in("send_message", payload, socket) when is_map(payload) do
    session = Map.take(socket.assigns, [:conversation_id, :sagents_subs])

    case Chat.send_message(session, socket.assigns.current_user, payload["text"]) do
      {:ok, changes} -> {:reply, {:ok, %{}}, assign(socket, :sagents_subs, changes.sagents_subs)}
      error -> {:reply, {:error, Errors.from_business(error)}, socket}
    end
  end

  def handle_in("cancel", _payload, socket) do
    case Chat.cancel(socket.assigns.conversation_id) do
      :ok -> {:reply, {:ok, %{}}, socket}
      error -> {:reply, {:error, Errors.from_business(error)}, socket}
    end
  end

  # A sheet a user opened in this conversation (ST-2). It is linked, but
  # nobody's active tab moves: there is no `focus_sheet`.
  def handle_in("open_sheet", %{"sheet_id" => sheet_id}, socket) do
    conversation_id = socket.assigns.conversation_id

    case Sheets.link(conversation_id, sheet_id, :opened) do
      {:ok, link} ->
        :ok = Conversations.broadcast_event(conversation_id, {:sheets_changed})
        linked = Enum.find(Sheets.list_links(conversation_id), &(&1.sheet.id == link.sheet_id))
        {:reply, {:ok, %{sheet: ConversationJSON.linked_sheet(linked)}}, socket}

      error ->
        {:reply, {:error, Errors.from_business(error)}, socket}
    end
  end

  def handle_in("open_sheet", _payload, socket),
    do: reply_error(socket, :invalid_op, "the payload must have a \"sheet_id\"")

  def handle_in(event, _payload, socket),
    do: reply_error(socket, :invalid_op, "unknown event #{inspect(event)}")

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    user_ref = SheetJSON.user_ref(socket.assigns.current_user)

    {:ok, _ref} =
      Coordinator.track_conversation_viewer(socket.assigns.conversation_id, user_ref.id, %{
        user: user_ref
      })

    push_participants(socket)
    {:noreply, socket}
  end

  def handle_info({:agent, agent_id, event}, %{assigns: %{agent_id: agent_id}} = socket) do
    {pushes, events} = ConversationEvents.translate(event, socket.assigns.events)
    Enum.each(pushes, fn {name, payload} -> push(socket, name, payload) end)

    socket =
      case event do
        {:display_message_saved, message} -> saw_message(socket, message)
        _other -> socket
      end

    {:noreply, assign(socket, :events, events)}
  end

  # The agent went down: the subscription goes back to `:pending` until the
  # agent's next presence join.
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case Subscriber.handle_publisher_down(socket.assigns.sagents_subs, ref, reason) do
      {:matched, subs} -> {:noreply, assign(socket, :sagents_subs, subs)}
      :no_match -> {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic, payload: diff},
        socket
      ) do
    {subs, revived} =
      Subscriber.handle_presence_diff(socket.assigns.sagents_subs, topic, diff, report: true)

    socket = assign(socket, :sagents_subs, subs)

    if Map.has_key?(socket.assigns, :conversation_id) and revived != [],
      do: {:noreply, push_messages_since_last(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:sheets_changed}, socket) do
    links = Sheets.list_links(socket.assigns.conversation_id)
    push(socket, "sheets", ConversationJSON.sheets(links))
    {:noreply, socket}
  end

  def handle_info({:focus_sheet, sheet_id, reason}, socket) do
    push(socket, "focus_sheet", %{sheet_id: sheet_id, reason: to_string(reason)})
    {:noreply, socket}
  end

  def handle_info({:agent, _other_agent_id, _event}, socket), do: {:noreply, socket}

  @impl Phoenix.Channel
  def handle_out("presence_diff", _diff, socket) do
    push_participants(socket)
    {:noreply, socket}
  end

  defp push_participants(socket),
    do: push(socket, "participants", SheetJSON.participants(Presence.user_refs(socket)))

  # Messages stored while this channel wasn't subscribed. Messages at the
  # newest timestamp already sent are sent again, since several items of one
  # message share a timestamp.
  defp push_messages_since_last(socket) do
    since = socket.assigns.last_message_at

    scope(socket)
    |> Conversations.load_display_messages(socket.assigns.conversation_id)
    |> Enum.filter(&(is_nil(since) or DateTime.compare(&1.inserted_at, since) != :lt))
    |> Enum.reduce(socket, fn message, socket ->
      push(socket, "message", %{message: MessageJSON.message(message)})
      saw_message(socket, message)
    end)
  end

  defp saw_message(socket, message) do
    last = socket.assigns.last_message_at

    if is_nil(last) or DateTime.compare(message.inserted_at, last) == :gt,
      do: assign(socket, :last_message_at, message.inserted_at),
      else: socket
  end

  defp inserted_at(nil), do: nil
  defp inserted_at(message), do: message.inserted_at

  defp scope(socket), do: Scope.for_user(socket.assigns.current_user)

  defp reply_error(socket, code, message),
    do: {:reply, {:error, Errors.from_business({:error, code, message, %{}})}, socket}
end
