defmodule SpreadSheetAi.Agents.AgentPersistence do
  @moduledoc """
  Implements `Sagents.AgentPersistence` for state snapshots.

  Persists full agent state (messages, todos, metadata) to the database
  via `SpreadSheetAi.Conversations.save_agent_state/3`, and mirrors the
  durable interrupt flag onto `conversation.metadata["interrupted"]` via
  `set_interrupted/3` (called by sagents only on actual transitions).

  It is also the one writer of generated titles (CS-8): on the
  `:on_title_generated` lifecycle it copies the title from the state's
  metadata to `conversations.title`. Viewers only update their own copy.
  """

  @behaviour Sagents.AgentPersistence

  require Logger

  @impl true
  def persist_state(scope, state_data, context) do
    conversation_id = extract_conversation_id(context.agent_id)

    case SpreadSheetAi.Conversations.save_agent_state(scope, conversation_id, state_data) do
      {:ok, _agent_state} ->
        Logger.debug("Persisted agent state for #{context.agent_id} (#{context.lifecycle})")
        maybe_put_title(scope, conversation_id, state_data, context)

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if conversation_deleted?(errors) do
          Logger.warning(
            "Skipping agent state persistence for #{context.agent_id} (#{context.lifecycle}): conversation no longer exists"
          )

          :ok
        else
          error
        end

      {:error, :not_found} ->
        Logger.warning(
          "Skipping agent state persistence for #{context.agent_id} (#{context.lifecycle}): conversation not accessible in scope"
        )

        :ok
    end
  end

  @impl true
  def load_state(scope, context) do
    conversation_id = extract_conversation_id(context.agent_id)
    SpreadSheetAi.Conversations.load_agent_state(scope, conversation_id)
  end

  @impl true
  def set_interrupted(scope, context, interrupted?) do
    conversation_id = extract_conversation_id(context.agent_id)

    case SpreadSheetAi.Conversations.set_interrupt_status(scope, conversation_id, interrupted?) do
      {:ok, _conversation} ->
        :ok

      {:error, :not_found} ->
        Logger.warning(
          "Skipping interrupt flag update for #{context.agent_id}: conversation not accessible in scope"
        )

        :ok

      other ->
        Logger.warning(
          "Failed to update interrupt flag for #{context.agent_id}: #{inspect(other)}"
        )

        :ok
    end
  end

  # `Sagents.Middleware.ConversationTitle` stores the title in the state
  # metadata before the persist that follows its event.
  defp maybe_put_title(scope, conversation_id, state_data, %{lifecycle: :on_title_generated}) do
    case get_in(state_data, ["state", "metadata", "conversation_title"]) do
      title when is_binary(title) ->
        case SpreadSheetAi.Conversations.put_title(scope, conversation_id, title) do
          {:ok, _conversation} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to write conversation title: #{inspect(reason)}")
        end

      _none ->
        :ok
    end

    :ok
  end

  defp maybe_put_title(_scope, _conversation_id, _state_data, _context), do: :ok

  defp extract_conversation_id(agent_id) do
    String.replace_prefix(agent_id, "conversation-", "")
  end

  defp conversation_deleted?(changeset_errors) do
    Enum.any?(changeset_errors, fn
      {:conversation_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :foreign
      _other -> false
    end)
  end
end
