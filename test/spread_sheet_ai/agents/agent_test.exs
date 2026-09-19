defmodule SpreadSheetAi.Agents.AgentTest do
  # Agents run under the global Sagents supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  # Sagents 0.15.1 updates an agent's presence before tracking it, which logs
  # a harmless ":nopresence" warning on every agent start.
  @moduletag :capture_log

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures

  alias LangChain.ChatModels.ChatReqLLM
  alias LangChain.Message
  alias Sagents.AgentServer
  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Agents.ChatModels
  alias SpreadSheetAi.Conversations
  alias SpreadSheetAi.Test.ScriptedChatModel

  setup do
    start_supervised!(ScriptedChatModel)
    alice = verified_user_fixture(%{display_name: "Alice"})
    %{alice: alice, conversation: conversation_fixture(alice)}
  end

  describe "a conversation's agent" do
    test "replies with the scripted model and saves the display messages", %{
      alice: alice,
      conversation: conversation
    } do
      ScriptedChatModel.push(["Hello Alice!"])
      agent_id = start_agent!(conversation, alice)

      :ok =
        AgentServer.add_message(agent_id, llm_message(alice, "hi"), display: display(alice, "hi"))

      assert_receive {:agent, ^agent_id, {:status_changed, :running, _}}
      assert_receive {:agent, ^agent_id, {:llm_deltas, _deltas}}
      assert_receive {:agent, ^agent_id, {:status_changed, :idle, _}}
      assert_receive {:agent, ^agent_id, {:conversation_title_generated, "Scripted title", _}}

      assert [user_message, reply] =
               Conversations.load_display_messages(Scope.for_user(alice), conversation.id)

      assert %{message_type: "user", content: %{"text" => "hi"}} = user_message

      assert user_message.metadata == %{
               "sender_user_id" => alice.id,
               "sender_display_name" => "Alice"
             }

      assert %{message_type: "assistant", content: %{"text" => "Hello Alice!"}} = reply

      # The model saw the sender-prefixed text.
      assert [{messages, []}] = ScriptedChatModel.calls()
      assert Message.ContentPart.parts_to_string(List.last(messages).content) == "[Alice]: hi"
    end

    test "writes the generated title to the conversation", %{
      alice: alice,
      conversation: conversation
    } do
      ScriptedChatModel.push(["Hello Alice!"])
      ScriptedChatModel.push(:title, ["Budget planning"])
      agent_id = start_agent!(conversation, alice)

      :ok =
        AgentServer.add_message(agent_id, llm_message(alice, "hi"), display: display(alice, "hi"))

      assert_receive {:agent, ^agent_id, {:conversation_title_generated, "Budget planning", _}}
      # The title is persisted right after that event, in the same server
      # message; a call to the server waits for it.
      AgentServer.get_status(agent_id)

      assert {:ok, %{title: "Budget planning"}} =
               Conversations.get_conversation(Scope.for_user(alice), conversation.id)
    end
  end

  test "conversations are shared between users", %{alice: alice, conversation: conversation} do
    bob = Scope.for_user(verified_user_fixture())

    assert {:ok, found} = Conversations.get_conversation(bob, conversation.id)
    assert found.user_id == alice.id

    {:ok, _message} = Conversations.append_text_message(bob, conversation.id, "user", "hello")

    assert [%{content: %{"text" => "hello"}}] =
             Conversations.load_display_messages(bob, conversation.id)
  end

  describe "ChatModels" do
    setup do
      ai = Application.fetch_env!(:spread_sheet_ai, :ai)
      Application.put_env(:spread_sheet_ai, :ai, Keyword.delete(ai, :chat_model_builder))
      on_exit(fn -> Application.put_env(:spread_sheet_ai, :ai, ai) end)
      %{ai: ai}
    end

    test "build OpenRouter models through ReqLLM by default", %{ai: ai} do
      assert %ChatReqLLM{model: model, stream: true, max_tokens: max_tokens} = ChatModels.main()
      assert model == ai[:model]
      assert max_tokens == ai[:max_tokens]

      assert %ChatReqLLM{model: title_model, stream: false} = ChatModels.title()
      assert title_model == ai[:title_model]
    end
  end

  defp llm_message(user, text),
    do: with_sender(Message.new_user!("[#{user.display_name}]: #{text}"), user)

  defp display(user, text), do: with_sender(Message.new_user!(text), user)

  defp with_sender(message, user) do
    %{
      message
      | metadata: %{"sender_user_id" => user.id, "sender_display_name" => user.display_name}
    }
  end
end
