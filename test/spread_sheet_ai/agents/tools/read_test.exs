defmodule SpreadSheetAi.Agents.Tools.ReadTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Agents.Tools.Read
  alias SpreadSheetAi.Conversations
  alias SpreadSheetAi.Sheets

  setup do
    user = verified_user_fixture()
    conversation = conversation_fixture(user)
    :ok = Conversations.subscribe_events(conversation.id)

    sheet =
      created_sheet_fixture(%{
        "name" => "P&L 2026",
        "columns" => [
          %{"name" => "Q1", "column_type" => "number"},
          %{"name" => "Note", "column_type" => "text"}
        ],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200, "Note" => "up"}},
          %{"label" => "Cost of revenue", "values" => %{"Q1" => 400}},
          %{"label" => "Payroll", "values" => %{}}
        ]
      })

    %{sheet: sheet, conversation: conversation, context: tool_context(conversation, user)}
  end

  test "list_sheets lists every sheet with its size, and links nothing", %{
    sheet: sheet,
    context: context
  } do
    assert {:ok, json} = Read.list_sheets(%{}, context)

    assert %{"id" => sheet.id, "name" => "P&L 2026", "rows" => 3, "columns" => 3} in Jason.decode!(
             json
           )

    assert Sheets.list_links(context.conversation_id) == []
    refute_receive {:focus_sheet, _, _}
  end

  test "open_sheet returns the structure and links the sheet as opened", %{
    sheet: sheet,
    context: context
  } do
    assert {:ok, json} = Read.open_sheet(%{"sheet_id" => sheet.id}, context)

    assert Jason.decode!(json) == %{
             "id" => sheet.id,
             "name" => "P&L 2026",
             "columns" => [
               %{"name" => "Line item", "type" => "text", "is_label" => true},
               %{"name" => "Q1", "type" => "number", "is_label" => false},
               %{"name" => "Note", "type" => "text", "is_label" => false}
             ],
             "row_count" => 3,
             "version" => 1
           }

    assert_linked(sheet.id, context, :opened)
  end

  describe "read_rows" do
    test "reads a page, optionally some columns, and links the sheet as read", %{
      sheet: sheet,
      context: context
    } do
      args = %{"sheet_id" => sheet.id, "offset" => 1, "limit" => 1, "columns" => ["q1"]}
      assert {:ok, json} = Read.read_rows(args, context)

      assert Jason.decode!(json) == %{
               "rows" => [%{"label" => "Cost of revenue", "values" => %{"Q1" => 400}}],
               "total" => 3,
               "offset" => 1
             }

      assert_linked(sheet.id, context, :read)
    end

    test "defaults to the first page of every column", %{sheet: sheet, context: context} do
      assert {:ok, json} = Read.read_rows(%{"sheet_id" => sheet.id}, context)
      assert %{"rows" => [revenue, _, payroll], "offset" => 0} = Jason.decode!(json)
      assert revenue == %{"label" => "Revenue", "values" => %{"Q1" => 1200, "Note" => "up"}}
      assert payroll == %{"label" => "Payroll", "values" => %{"Q1" => nil, "Note" => nil}}
    end

    test "an unknown column lists the existing ones, and links nothing", %{
      sheet: sheet,
      context: context
    } do
      assert {:error, text} =
               Read.read_rows(%{"sheet_id" => sheet.id, "columns" => ["Q3"]}, context)

      assert text ==
               """
               ERROR unknown_column: column "Q3" does not exist in sheet "P&L 2026".
               Existing columns: Line item, Q1, Note.\
               """

      assert_not_linked(context)
    end

    test "bad argument types are rejected before the sheet is called", %{
      sheet: sheet,
      context: context
    } do
      for args <- [
            %{},
            %{"sheet_id" => 1},
            %{"sheet_id" => sheet.id, "offset" => -1},
            %{"sheet_id" => sheet.id, "limit" => 0},
            %{"sheet_id" => sheet.id, "limit" => "10"},
            %{"sheet_id" => sheet.id, "columns" => "Q1"},
            %{"sheet_id" => sheet.id, "columns" => [1]}
          ] do
        assert {:error, "ERROR invalid_arguments: " <> _} = Read.read_rows(args, context)
      end

      assert_not_linked(context)
    end
  end

  describe "read_cells" do
    test "reads rows × columns and links the sheet as read", %{sheet: sheet, context: context} do
      args = %{"sheet_id" => sheet.id, "rows" => ["revenue", "Payroll"], "columns" => ["Q1"]}
      assert {:ok, json} = Read.read_cells(args, context)

      assert Jason.decode!(json) == %{
               "cells" => %{"Revenue" => %{"Q1" => 1200}, "Payroll" => %{"Q1" => nil}}
             }

      assert_linked(sheet.id, context, :read)
    end

    test "an unknown row points to find_rows", %{sheet: sheet, context: context} do
      args = %{"sheet_id" => sheet.id, "rows" => ["Tax"], "columns" => ["Q1"]}
      assert {:error, text} = Read.read_cells(args, context)

      assert text ==
               """
               ERROR unknown_row: row "Tax" does not exist in sheet "P&L 2026".
               Use find_rows or read_rows to look up the exact row labels.\
               """
    end

    test "rows and columns must be non-empty lists of strings", %{sheet: sheet, context: context} do
      for args <- [
            %{"sheet_id" => sheet.id, "rows" => [], "columns" => ["Q1"]},
            %{"sheet_id" => sheet.id, "rows" => ["Revenue"]},
            %{"sheet_id" => sheet.id, "rows" => "Revenue", "columns" => ["Q1"]}
          ] do
        assert {:error, "ERROR invalid_arguments: " <> _} = Read.read_cells(args, context)
      end
    end
  end

  test "find_rows matches labels and links the sheet as read", %{sheet: sheet, context: context} do
    assert {:ok, json} = Read.find_rows(%{"sheet_id" => sheet.id, "query" => "REV"}, context)

    assert Jason.decode!(json) == %{
             "rows" => ["Revenue", "Cost of revenue"],
             "truncated" => false
           }

    assert_linked(sheet.id, context, :read)
  end

  test "an unknown or malformed sheet id is not_found, pointing to list_sheets", %{
    context: context
  } do
    for sheet_id <- [Ecto.UUID.generate(), "nope"] do
      assert {:error, text} = Read.open_sheet(%{"sheet_id" => sheet_id}, context)

      assert text ==
               "ERROR not_found: sheet not found.\nUse list_sheets to find sheet ids."
    end

    assert_not_linked(context)
  end

  defp assert_linked(sheet_id, context, kind) do
    assert_receive {:focus_sheet, ^sheet_id, ^kind}
    assert_receive {:sheets_changed}
    last_access = Atom.to_string(kind)

    assert [%{sheet: %{id: ^sheet_id}, last_access: ^last_access}] =
             Sheets.list_links(context.conversation_id)
  end

  defp assert_not_linked(context) do
    refute_receive {:focus_sheet, _, _}
    assert Sheets.list_links(context.conversation_id) == []
  end
end
