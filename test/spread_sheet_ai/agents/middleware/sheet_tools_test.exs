defmodule SpreadSheetAi.Agents.Middleware.SheetToolsTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  import SpreadSheetAi.ConversationsFixtures
  import SpreadSheetAi.SheetsFixtures

  alias LangChain.Message
  alias Sagents.State
  alias SpreadSheetAi.Agents.Middleware.SheetTools
  alias SpreadSheetAi.Sheets

  setup do
    %{conversation: conversation_fixture()}
  end

  describe "before_model/2" do
    test "puts the linked sheets before the latest user message only", %{
      conversation: conversation
    } do
      sheet =
        created_sheet_fixture(%{
          "name" => "P&L",
          "columns" => [%{"name" => "Due", "column_type" => "date"}],
          "rows" => [%{"label" => "Rent", "values" => %{"Due" => "2026-10-01"}}]
        })

      {:ok, _link} = Sheets.link(conversation.id, sheet.id, :read)

      messages = [
        Message.new_user!("[Alice]: hi"),
        Message.new_assistant!("Hello"),
        Message.new_user!("[Bob]: when is rent due?")
      ]

      state = State.new!(%{messages: messages, conversation_id: conversation.id})
      assert {:ok, %State{messages: [first, reply, last]}} = SheetTools.before_model(state, %{})

      assert first == Enum.at(messages, 0)
      assert reply == Enum.at(messages, 1)
      assert [block, said] = last.content
      assert said.content == "[Bob]: when is rent due?"

      assert block.content == """
             <linked_sheets>
             - "P&L" (id: #{sheet.id}), 1 rows. Columns: Line item (text, line item), Due (date)
             </linked_sheets>\
             """

      refute block.content =~ "2026-10-01"
    end

    test "says when nothing is linked", %{conversation: conversation} do
      state =
        State.new!(%{messages: [Message.new_user!("hi")], conversation_id: conversation.id})

      assert {:ok, %State{messages: [%{content: [block, _said]}]}} =
               SheetTools.before_model(state, %{})

      assert block.content =~ "No sheets are linked to this conversation yet"
    end

    test "leaves a state with no user message alone", %{conversation: conversation} do
      state = State.new!(%{messages: [], conversation_id: conversation.id})
      assert SheetTools.before_model(state, %{}) == {:ok, state}
    end
  end

  test "tools/1 gives the 16 sheet tools, with strict argument schemas" do
    tools = SheetTools.tools(%{})
    assert length(tools) == 16
    assert tools |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 16

    for tool <- tools do
      assert %{"type" => "object", "additionalProperties" => false} = tool.parameters_schema
      assert is_binary(tool.display_text) and is_binary(tool.description)
    end
  end
end
