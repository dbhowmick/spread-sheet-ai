defmodule SpreadSheetAiWeb.ConversationEventsTest do
  use ExUnit.Case, async: true

  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.MessageDelta
  alias SpreadSheetAi.Conversations.DisplayMessage
  alias SpreadSheetAiWeb.ConversationEvents

  @idle ConversationEvents.new("idle")

  describe "join_status/1" do
    test "maps the agent status to the contract's" do
      assert ConversationEvents.join_status(:not_running) == "not_started"

      for status <- [:idle, :running, :cancelled, :error],
          do: assert(ConversationEvents.join_status(status) == Atom.to_string(status))

      assert ConversationEvents.join_status(:interrupted) == "idle"
    end
  end

  describe "status" do
    test "is pushed only when it changes" do
      {pushes, state} = translate(@idle, {:status_changed, :running, nil})
      assert pushes == [{"status", %{status: "running", error: nil}}]

      assert {[], ^state} = translate(state, {:status_changed, :running, nil})
    end

    test "an error carries its message" do
      error = LangChainError.exception(message: "rate limited")

      assert {[{"status", %{status: "error", error: "rate limited"}}], %{status: "error"}} =
               translate(@idle, {:status_changed, :error, error})

      assert {[{"status", %{error: ":boom"}}], _state} =
               translate(@idle, {:status_changed, :error, :boom})
    end

    test "an agent shutdown reads as idle, once" do
      running = %{@idle | status: "running"}

      {pushes, state} = translate(running, {:agent_shutdown, %{reason: :inactivity}})
      assert pushes == [{"status", %{status: "idle", error: nil}}]
      assert {[], _state} = translate(state, {:agent_shutdown, %{reason: :inactivity}})
    end

    test "interrupted and paused are not pushed" do
      assert {[], @idle} = translate(@idle, {:status_changed, :interrupted, %{}})
      assert {[], @idle} = translate(@idle, {:status_changed, :paused, nil})
    end
  end

  describe "streaming" do
    test "deltas push only their new text" do
      deltas = [delta("Hel"), delta("lo")]

      assert {[{"stream_delta", %{text: "Hello"}}], %{streaming?: true}} =
               translate(@idle, {:llm_deltas, deltas})
    end

    test "a delta with no text pushes nothing" do
      assert {[], %{streaming?: false}} = translate(@idle, {:llm_deltas, [delta(nil)]})
    end

    test "the AI's stored message closes the stream" do
      state = %{@idle | streaming?: true}
      message = display_message("assistant", "text", %{"text" => "Hello"})

      assert {[{"stream_reset", %{}}, {"message", %{message: %{content: %{"text" => "Hello"}}}}],
              %{streaming?: false}} = translate(state, {:display_message_saved, message})
    end

    test "a user's queued message doesn't close the stream" do
      state = %{@idle | streaming?: true}
      message = display_message("user", "text", %{"text" => "wait"})

      assert {[{"message", _}], %{streaming?: true}} =
               translate(state, {:display_message_saved, message})
    end

    test "a status that ends the run closes the stream first" do
      state = %{@idle | status: "running", streaming?: true}

      assert {[{"stream_reset", %{}}, {"status", %{status: "cancelled"}}], %{streaming?: false}} =
               translate(state, {:status_changed, :cancelled, nil})
    end

    test "running doesn't close the stream" do
      state = %{@idle | streaming?: true}

      assert {[{"status", %{status: "running"}}], %{streaming?: true}} =
               translate(state, {:status_changed, :running, nil})
    end
  end

  describe "messages" do
    test "an update is message_updated" do
      message = display_message("assistant", "tool_call", %{"call_id" => "c1", "name" => "x"})

      assert {[{"message_updated", %{message: %{content_type: "tool_call"}}}], @idle} =
               translate(@idle, {:display_message_updated, message})
    end

    test "a queued message names its sender, without the speaker prefix" do
      message = %{
        Message.new_user!("[Bob]: and Q4?")
        | metadata: %{"sender_user_id" => "bob-id", "sender_display_name" => "Bob"}
      }

      assert {[
                {"message_queued",
                 %{sender: %{id: "bob-id", display_name: "Bob"}, text: "and Q4?"}}
              ], @idle} = translate(@idle, {:message_queued, message})
    end

    test "a generated title is pushed" do
      assert {[{"title", %{title: "Budget"}}], @idle} =
               translate(@idle, {:conversation_title_generated, "Budget", "agent"})
    end
  end

  describe "tool status" do
    test "keeps the label from identification to completion" do
      identified = %{call_id: "c1", name: "set_cells", display_text: "Setting cells"}
      {[{"tool_status", pushed}], state} = translate(@idle, {:tool_call_identified, identified})

      assert pushed == %{
               call_id: "c1",
               name: "set_cells",
               display_text: "Setting cells",
               status: "identified"
             }

      completed = %{call_id: "c1", name: "set_cells", result: "ok"}

      assert {[{"tool_status", %{display_text: "Setting cells", status: "completed"}}], _state} =
               translate(state, {:tool_execution_update, :completed, completed})
    end

    test "falls back to the tool name" do
      assert {[{"tool_status", %{display_text: "read_rows", status: "failed"}}], _state} =
               translate(
                 @idle,
                 {:tool_execution_update, :failed, %{call_id: "c2", name: "read_rows"}}
               )
    end

    test "is skipped while the call has no id" do
      assert {[], @idle} =
               translate(@idle, {:tool_call_identified, %{call_id: nil, name: "read_rows"}})
    end
  end

  test "other events push nothing" do
    for event <- [
          {:chain_error, LangChainError.exception(message: "x")},
          {:llm_message, Message.new_assistant!("hi")},
          {:llm_token_usage, %{}},
          {:state_restored, %{}},
          {:todos_updated, []},
          {:node_transferring, %{}}
        ] do
      assert {[], @idle} = translate(@idle, event)
    end
  end

  defp translate(state, event), do: ConversationEvents.translate(event, state)

  defp delta(content), do: %MessageDelta{role: :assistant, content: content}

  defp display_message(type, content_type, content) do
    %DisplayMessage{
      id: Ecto.UUID.generate(),
      message_type: type,
      content_type: content_type,
      content: content,
      status: "completed",
      metadata: %{},
      inserted_at: DateTime.utc_now()
    }
  end
end
