defmodule SpreadSheetAiWeb.MessageJSONTest do
  use ExUnit.Case, async: true

  alias SpreadSheetAi.Conversations.DisplayMessage
  alias SpreadSheetAiWeb.MessageJSON

  test "a user's text message names its sender" do
    message =
      display_message("user", "text", %{"text" => "Add Q3"},
        metadata: %{"sender_user_id" => "alice-id", "sender_display_name" => "Alice"}
      )

    assert MessageJSON.message(message) == %{
             id: message.id,
             role: "user",
             content_type: "text",
             content: %{"text" => "Add Q3"},
             sender: %{id: "alice-id", display_name: "Alice"},
             status: "completed",
             inserted_at: message.inserted_at
           }
  end

  test "only user messages have a sender" do
    message =
      display_message("assistant", "text", %{"text" => "Done"},
        metadata: %{"sender_user_id" => "x"}
      )

    assert %{sender: nil} = MessageJSON.message(message)

    assert %{sender: nil} =
             MessageJSON.message(display_message("user", "text", %{"text" => "hi"}))
  end

  test "rows Sagents writes itself read as the AI's" do
    content = %{"text" => "Agent execution cancelled.", "stop_reason" => "cancelled"}

    assert %{role: "assistant", content_type: "notification", content: ^content} =
             MessageJSON.message(display_message("system", "notification", content))

    assert %{role: "assistant", content: %{"text" => "Overloaded", "error_type" => nil}} =
             MessageJSON.message(display_message("system", "error", %{"text" => "Overloaded"}))
  end

  test "content keeps the contract's keys and a stop reason" do
    content = %{"text" => "Half", "stop_reason" => "length", "stop_details" => %{"x" => 1}}

    assert %{content: %{"text" => "Half", "stop_reason" => "length"}} =
             MessageJSON.message(display_message("assistant", "text", content))

    assert %{content: %{"text" => "hmm"}} =
             MessageJSON.message(display_message("assistant", "thinking", %{"text" => "hmm"}))
  end

  test "a tool call's label falls back to its name" do
    content = %{"call_id" => "c1", "name" => "read_rows", "arguments" => %{"sheet_id" => "s"}}

    assert %{
             role: "assistant",
             status: "executing",
             content: %{
               "call_id" => "c1",
               "name" => "read_rows",
               "display_text" => "read_rows",
               "arguments" => %{"sheet_id" => "s"}
             }
           } =
             MessageJSON.message(
               display_message("assistant", "tool_call", content, status: "executing")
             )
  end

  test "a tool result" do
    content = %{"tool_call_id" => "c1", "name" => "read_rows", "content" => "[]"}

    assert %{role: "tool", content: %{"is_error" => false, "content" => "[]"}} =
             MessageJSON.message(display_message("tool", "tool_result", content))
  end

  test "an interrupted tool call reads as pending" do
    message =
      display_message("assistant", "tool_call", %{"call_id" => "c1", "name" => "x"},
        status: "interrupted"
      )

    assert %{status: "pending"} = MessageJSON.message(message)
  end

  defp display_message(type, content_type, content, opts \\ []) do
    %DisplayMessage{
      id: Ecto.UUID.generate(),
      message_type: type,
      content_type: content_type,
      content: content,
      status: Keyword.get(opts, :status, "completed"),
      metadata: Keyword.get(opts, :metadata, %{}),
      inserted_at: DateTime.utc_now()
    }
  end
end
