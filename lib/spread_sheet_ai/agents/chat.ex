defmodule SpreadSheetAi.Agents.Chat do
  @moduledoc """
  What people do in a conversation's chat: send a message, stop the AI's
  turn, and ask for its status (docs/backend-plan.md §7.3). Used by
  `SpreadSheetAiWeb.ConversationChannel`.

  Errors are `{:error, code, message, meta}`, as in `SpreadSheetAi.Sheets`.
  """

  require Logger

  alias LangChain.Message
  alias Sagents.AgentServer
  alias SpreadSheetAi.Accounts.{Scope, User}
  alias SpreadSheetAi.Agents.Coordinator

  @type error :: {:error, atom(), String.t(), map()}

  # What a second `execute` returns when two messages reach an idle agent
  # back to back: both were added, and the first `execute` started a run
  # that already holds the second message.
  @already_running "Cannot execute, server is in state: running"

  @doc """
  Sends `user`'s message to the conversation's agent, starting the agent if
  it isn't running. The calling process is subscribed to the agent's events.

  `session` holds `:conversation_id` and the caller's `:sagents_subs`. On
  success, returns the changes to merge into it (`:agent_id` and
  `:sagents_subs`).

  The model sees `"[Name]: text"`, so it knows who is speaking (CS-3); the
  transcript shows `text`. Both carry the sender in their metadata
  (`"sender_user_id"`, `"sender_display_name"`). A message sent while the AI
  is busy is queued by the agent and handled after the current turn (CS-4).
  """
  @spec send_message(map(), User.t(), term()) :: {:ok, map()} | error()
  def send_message(%{conversation_id: _} = session, %User{} = user, text) do
    with {:ok, text} <- validate_text(text),
         {:ok, changes} <- ensure_running(session, user),
         :ok <- add_message(changes.agent_id, user, text) do
      {:ok, changes}
    end
  end

  @doc "Stops the AI's current turn (CS-5). `not_running` when there is none."
  @spec cancel(String.t()) :: :ok | error()
  def cancel(conversation_id) do
    case AgentServer.cancel(Coordinator.conversation_agent_id(conversation_id)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_running, "The AI is not running.", %{}}
    end
  end

  @doc """
  The agent's status, or `:not_running` when no agent process is running
  for the conversation.
  """
  @spec status(String.t()) :: atom()
  def status(conversation_id),
    do: AgentServer.get_status(Coordinator.conversation_agent_id(conversation_id))

  defp validate_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> invalid_text("can't be blank")
      text -> {:ok, text}
    end
  end

  defp validate_text(_text), do: invalid_text("must be a string")

  defp invalid_text(problem),
    do: {:error, :validation_failed, "The message text #{problem}.", %{field: "text"}}

  defp ensure_running(session, user) do
    state = %{
      conversation_id: session.conversation_id,
      current_scope: Scope.for_user(user),
      sagents_subs: Map.get(session, :sagents_subs, %{})
    }

    case Coordinator.ensure_agent_session_running(state) do
      {:ok, changes} ->
        {:ok, changes}

      {:error, reason} ->
        Logger.error("Could not start the agent: #{inspect(reason)}")
        {:error, :internal_error, "The AI could not be started.", %{}}
    end
  end

  defp add_message(agent_id, user, text) do
    name = User.display_name(user)
    metadata = %{"sender_user_id" => user.id, "sender_display_name" => name}
    llm_message = %{Message.new_user!("[#{name}]: #{text}") | metadata: metadata}
    display_message = %{Message.new_user!(text) | metadata: metadata}

    case AgentServer.add_message(agent_id, llm_message, display: display_message) do
      :ok ->
        :ok

      {:error, @already_running} ->
        Logger.info("Message added while another started the run: #{agent_id}")
        :ok

      {:error, reason} ->
        Logger.error("Could not add the message: #{inspect(reason)}")
        {:error, :internal_error, "The message could not be sent.", %{}}
    end
  end
end
