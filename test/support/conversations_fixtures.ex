defmodule SpreadSheetAi.ConversationsFixtures do
  @moduledoc """
  Test fixtures for conversations and their agents.

  `start_agent!/2` starts a conversation's agent with the calling test
  process subscribed to its events (`{:agent, agent_id, event}`), and stops
  the agent when the test exits, before the sandbox owner does. Tests that
  start agents must be `async: false` and start
  `SpreadSheetAi.Test.ScriptedChatModel`.
  """

  import ExUnit.Assertions, only: [assert_receive: 1, flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Agents.Coordinator
  alias SpreadSheetAi.AuthFixtures
  alias SpreadSheetAi.Conversations

  @doc "Creates a conversation created by `user` (a new verified user by default)."
  def conversation_fixture(user \\ AuthFixtures.verified_user_fixture(), attrs \\ %{}) do
    {:ok, conversation} = Conversations.create_conversation(Scope.for_user(user), attrs)
    conversation
  end

  @doc """
  The tool context Sagents passes to a tool function running in the
  conversation's agent, for calling tools directly.
  """
  def tool_context(conversation, user) do
    %{
      conversation_id: conversation.id,
      agent_id: Coordinator.conversation_agent_id(conversation.id),
      scope: Scope.for_user(user)
    }
  end

  @doc """
  Stops the conversation's agent when the test exits, before the sandbox
  owner does. For agents that something else (a channel) starts.
  Returns the conversation.
  """
  def stop_agent_on_exit(conversation) do
    on_exit(fn -> Coordinator.stop_conversation_session(conversation.id) end)
    conversation
  end

  @doc """
  Starts the conversation's agent as `user` and waits for its startup
  `:idle` status, so a later `{:status_changed, :idle, _}` is the end of a
  run. Returns the agent id.
  """
  def start_agent!(conversation, user) do
    {:ok, %{agent_id: agent_id}} =
      Coordinator.ensure_agent_session_running(%{
        conversation_id: conversation.id,
        current_scope: Scope.for_user(user)
      })

    stop_agent_on_exit(conversation)
    assert_receive {:agent, ^agent_id, {:status_changed, :idle, nil}}
    agent_id
  end

  @doc """
  Waits for the end of the agent's next run: its `:running` status, then the
  following `:idle`. Statuses are read in arrival order, so an `:idle` that
  came before the run (the startup one, or the snapshot sent on subscribe)
  is skipped rather than mistaken for the end.
  """
  def await_run_end(agent_id, timeout \\ 2_000), do: await_status(agent_id, false, timeout)

  defp await_status(agent_id, running?, timeout) do
    receive do
      {:agent, ^agent_id, {:status_changed, :running, _}} ->
        await_status(agent_id, true, timeout)

      {:agent, ^agent_id, {:status_changed, :idle, _}} when running? ->
        :ok

      {:agent, ^agent_id, {:status_changed, _status, _}} ->
        await_status(agent_id, running?, timeout)
    after
      timeout -> flunk("the agent's run didn't end")
    end
  end
end
