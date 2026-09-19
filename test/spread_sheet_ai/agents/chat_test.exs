defmodule SpreadSheetAi.Agents.ChatTest do
  # Agents run under the global Sagents supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  # See SpreadSheetAi.Agents.AgentTest.
  @moduletag :capture_log

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures

  alias LangChain.Message.ContentPart
  alias Sagents.{AgentServer, Subscriber}
  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Agents.Chat
  alias SpreadSheetAi.Conversations
  alias SpreadSheetAi.Test.ScriptedChatModel

  setup do
    start_supervised!(ScriptedChatModel)
    alice = verified_user_fixture(%{display_name: "Alice"})
    %{alice: alice, conversation: conversation_fixture(alice) |> stop_agent_on_exit()}
  end

  test "blank text is refused", %{alice: alice, conversation: conversation} do
    for text <- ["", "   ", nil, 12] do
      assert {:error, :validation_failed, _message, %{field: "text"}} =
               Chat.send_message(session(conversation), alice, text)
    end

    assert Chat.status(conversation.id) == :not_running
  end

  test "sends the message, starting the agent", %{alice: alice, conversation: conversation} do
    ScriptedChatModel.push(["Hello Alice!"])

    assert {:ok, %{agent_id: agent_id, sagents_subs: subs}} =
             Chat.send_message(session(conversation), alice, "  hi  ")

    assert %{{:agent, ^agent_id} => %{state: :subscribed}} = subs
    await_run_end(agent_id)

    assert [user_message, _reply] =
             Conversations.load_display_messages(Scope.for_user(alice), conversation.id)

    assert user_message.content == %{"text" => "hi"}

    assert user_message.metadata == %{
             "sender_user_id" => alice.id,
             "sender_display_name" => "Alice"
           }

    assert [{messages, _tools}] = ScriptedChatModel.calls()
    assert text(List.last(messages)) == "[Alice]: hi"
  end

  test "a message bumps the conversation's activity", %{alice: alice, conversation: conversation} do
    scope = Scope.for_user(alice)
    {:ok, _message} = Conversations.append_text_message(scope, conversation.id, "user", "hi")

    assert {:ok, touched} = Conversations.get_conversation(scope, conversation.id)
    assert DateTime.compare(touched.updated_at, conversation.updated_at) == :gt
  end

  test "cancel with nothing running is not_running", %{conversation: conversation} do
    assert {:error, :not_running, _message, %{}} = Chat.cancel(conversation.id)
  end

  # Two messages reach an idle agent back to back: both are added, the first
  # `execute` starts a run holding both, and the second `execute` fails
  # because that run is going. The second sender still gets `:ok`.
  test "two messages sent at once to an idle agent are both answered in one run", %{
    alice: alice,
    conversation: conversation
  } do
    bob = verified_user_fixture(%{display_name: "Bob"})
    test_pid = self()

    ScriptedChatModel.push([
      fn _messages, _tools ->
        send(test_pid, {:model_running, self()})

        receive do
          :release -> "Hi both"
        end
      end
    ])

    agent_id = start_agent!(conversation, alice)
    {:ok, pid} = AgentServer.fetch_pid(agent_id)

    # A subscribed subs map, so the senders make no subscribe call: while the
    # agent is suspended, only their two `add_message` calls queue up.
    subs = Subscriber.subscribe_to_agent(%{}, agent_id, tagged: true)
    session = %{conversation_id: conversation.id, sagents_subs: subs}

    :ok = :sys.suspend(pid)

    tasks =
      for user <- [alice, bob] do
        Task.async(fn -> Chat.send_message(session, user, "hello from #{user.display_name}") end)
      end

    wait_until(fn -> queued_adds(pid) == 2 end)
    :ok = :sys.resume(pid)

    assert [{:ok, _}, {:ok, _}] = Task.await_many(tasks)
    assert_receive {:model_running, model_pid}, 2_000
    send(model_pid, :release)
    await_run_end(agent_id)

    assert [{messages, _tools}] = ScriptedChatModel.calls()

    assert messages |> Enum.take(-2) |> Enum.map(&text/1) |> Enum.sort() == [
             "[Alice]: hello from Alice",
             "[Bob]: hello from Bob"
           ]
  end

  defp session(conversation), do: %{conversation_id: conversation.id, sagents_subs: %{}}

  # The message's own text, without the `<linked_sheets>` block SheetTools
  # puts in front of the latest user message.
  defp text(message) do
    message.content
    |> Enum.reject(&String.starts_with?(&1.content, "<linked_sheets>"))
    |> ContentPart.parts_to_string()
  end

  defp queued_adds(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.count(messages, &match?({:"$gen_call", _from, {:add_message, _, _}}, &1))
  end

  # Polls a condition that no message tells us about (a suspended process's
  # mailbox), for up to a second.
  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition not met")

      true ->
        receive do
        after
          10 -> wait_until(fun, tries - 1)
        end
    end
  end
end
