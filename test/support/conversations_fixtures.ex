defmodule SpreadSheetAi.ConversationsFixtures do
  @moduledoc """
  Test fixtures for conversations and their agents.

  `start_agent!/2` starts a conversation's agent with the calling test
  process subscribed to its events (`{:agent, agent_id, event}`), and stops
  the agent when the test exits, before the sandbox owner does. Tests that
  start agents must be `async: false` and start
  `SpreadSheetAi.Test.ScriptedChatModel`.
  """

  import ExUnit.Assertions, only: [assert_receive: 1]
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

    on_exit(fn -> Coordinator.stop_conversation_session(conversation.id) end)
    assert_receive {:agent, ^agent_id, {:status_changed, :idle, nil}}
    agent_id
  end
end
