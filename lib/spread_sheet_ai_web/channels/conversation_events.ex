defmodule SpreadSheetAiWeb.ConversationEvents do
  @moduledoc """
  Turns a conversation agent's Sagents events into contract pushes
  (contract §7.3, docs/backend-plan.md §7.3). Pure, so every translation is
  unit-tested; `SpreadSheetAiWeb.ConversationChannel` keeps the state and
  pushes the results.

  `translate/2` returns `{[{event, payload}], state}`. The state holds:

  - `:status`, the last status pushed. A status is only pushed when it
    changes: an agent shutdown, for example, arrives more than once.
  - `:streaming?`, whether a streaming bubble is open. The next stored AI
    message, or a status that ends the run, is preceded by `stream_reset`.
  - `:tool_labels`, each tool call's `display_text`, which Sagents sends
    when the call is identified but not when it completes or fails.
  """

  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.MessageDelta
  alias SpreadSheetAi.Conversations.DisplayMessage
  alias SpreadSheetAiWeb.MessageJSON

  @type push :: {String.t(), map()}
  @type state :: %{
          status: String.t(),
          streaming?: boolean(),
          tool_labels: %{optional(String.t()) => String.t()}
        }

  @statuses [:idle, :running, :cancelled, :error]

  @doc "The state for a channel whose join reply said `status`."
  @spec new(String.t()) :: state()
  def new(status), do: %{status: status, streaming?: false, tool_labels: %{}}

  @doc """
  The join reply's `status` (§7.1) for `SpreadSheetAi.Agents.Chat.status/1`.
  `:interrupted` and `:paused` don't happen (there is no human-in-the-loop)
  and read as `idle`.
  """
  @spec join_status(atom()) :: String.t()
  def join_status(:not_running), do: "not_started"
  def join_status(status) when status in @statuses, do: Atom.to_string(status)
  def join_status(_status), do: "idle"

  @doc "The pushes for one agent event, and the new state."
  @spec translate(term(), state()) :: {[push()], state()}
  def translate({:llm_deltas, deltas}, state) do
    case Enum.map_join(deltas, &delta_text/1) do
      "" -> {[], state}
      text -> {[{"stream_delta", %{text: text}}], %{state | streaming?: true}}
    end
  end

  # A user's message can be stored while the AI streams (it was queued), so
  # only the AI's own messages close the streaming bubble.
  def translate({:display_message_saved, %DisplayMessage{} = message}, state) do
    {resets, state} =
      if message.message_type == "user", do: {[], state}, else: stream_reset(state)

    {resets ++ [{"message", %{message: MessageJSON.message(message)}}], state}
  end

  def translate({:display_message_updated, %DisplayMessage{} = message}, state),
    do: {[{"message_updated", %{message: MessageJSON.message(message)}}], state}

  def translate({:tool_call_identified, %{call_id: call_id} = info}, state)
      when is_binary(call_id),
      do: tool_status(info, "identified", state)

  def translate({:tool_execution_update, status, %{call_id: call_id} = info}, state)
      when status in [:executing, :completed, :failed] and is_binary(call_id),
      do: tool_status(info, Atom.to_string(status), state)

  def translate({:status_changed, status, reason}, state) when status in @statuses,
    do: put_status(state, Atom.to_string(status), error_text(status, reason))

  # The agent stopped (idle timeout, no viewers). The next message starts it.
  def translate({:agent_shutdown, _data}, state), do: put_status(state, "idle", nil)

  def translate({:message_queued, %Message{} = message}, state) do
    metadata = message.metadata || %{}
    name = metadata["sender_display_name"]

    payload = %{
      sender: %{id: metadata["sender_user_id"], display_name: name},
      text: strip_speaker(content_text(message.content), name)
    }

    {[{"message_queued", payload}], state}
  end

  def translate({:conversation_title_generated, title, _agent_id}, state),
    do: {[{"title", %{title: title}}], state}

  # `:chain_error` duplicates `{:status_changed, :error, _}`; the rest
  # (`:llm_message`, token usage, restores, todos, node transfers) have no
  # push.
  def translate(_event, state), do: {[], state}

  defp put_status(%{status: status} = state, status, _error), do: {[], state}

  defp put_status(state, "running", error),
    do: {[{"status", %{status: "running", error: error}}], %{state | status: "running"}}

  defp put_status(state, status, error) do
    {resets, state} = stream_reset(state)

    {resets ++ [{"status", %{status: status, error: error}}],
     %{state | status: status, tool_labels: %{}}}
  end

  defp stream_reset(%{streaming?: true} = state),
    do: {[{"stream_reset", %{}}], %{state | streaming?: false}}

  defp stream_reset(state), do: {[], state}

  defp tool_status(info, status, state) do
    label =
      Map.get(info, :display_text) || Map.get(state.tool_labels, info.call_id) ||
        Map.get(info, :name)

    payload = %{call_id: info.call_id, name: Map.get(info, :name), display_text: label}

    {[{"tool_status", Map.put(payload, :status, status)}],
     %{state | tool_labels: Map.put(state.tool_labels, info.call_id, label)}}
  end

  defp error_text(:error, %LangChainError{message: message}), do: message
  defp error_text(:error, reason) when is_binary(reason), do: reason
  defp error_text(:error, reason), do: inspect(reason)
  defp error_text(_status, _reason), do: nil

  defp delta_text(%MessageDelta{content: content}), do: content_text(content)

  defp content_text(text) when is_binary(text), do: text
  defp content_text(%ContentPart{type: :text, content: text}) when is_binary(text), do: text
  defp content_text(parts) when is_list(parts), do: Enum.map_join(parts, &content_text/1)
  defp content_text(_content), do: ""

  defp strip_speaker(text, name) when is_binary(name),
    do: String.replace_prefix(text, "[#{name}]: ", "")

  defp strip_speaker(text, _name), do: text
end
