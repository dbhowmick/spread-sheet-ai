defmodule SpreadSheetAi.Agents.Tools.RowsAndCellsTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Agents.Tools.{Cells, Rows}
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
          %{"name" => "Q2", "column_type" => "number"}
        ],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200}},
          %{"label" => "Payroll", "values" => %{"Q1" => 300}}
        ]
      })

    :ok = Sheets.subscribe(sheet.id)

    %{sheet: sheet, context: tool_context(conversation, user)}
  end

  describe "rows" do
    test "add_rows adds many rows with values in one op", %{sheet: sheet, context: context} do
      args = %{
        "sheet_id" => sheet.id,
        "rows" => [
          %{"label" => "Rent", "values" => %{"Q1" => 90, "q2" => 95}},
          %{"label" => "Tax"}
        ],
        "position" => 1
      }

      assert {:ok, json} = Rows.add_rows(args, context)
      assert Jason.decode!(json) == %{"version" => 2, "added" => 2}
      assert_receive {:op_applied, %{version: 2, applied_op: %{"type" => "add_rows"}}}

      assert labels(sheet.id) == ["Revenue", "Rent", "Tax", "Payroll"]
      assert {:ok, %{"Rent" => %{"Q2" => 95}}} = Sheets.read_cells(sheet.id, ["Rent"], ["Q2"])
      assert_written(sheet.id, context)
    end

    test "delete_rows and move_row by label", %{sheet: sheet, context: context} do
      assert {:ok, json} =
               Rows.move_row(
                 %{"sheet_id" => sheet.id, "label" => "payroll", "position" => 0},
                 context
               )

      assert Jason.decode!(json) == %{"version" => 2}
      assert labels(sheet.id) == ["Payroll", "Revenue"]

      assert {:ok, json} =
               Rows.delete_rows(%{"sheet_id" => sheet.id, "labels" => ["Revenue"]}, context)

      assert Jason.decode!(json) == %{"version" => 3, "deleted" => 1}
      assert labels(sheet.id) == ["Payroll"]
      assert_written(sheet.id, context)
    end

    test "rejected rows change nothing", %{sheet: sheet, context: context} do
      args = %{"sheet_id" => sheet.id, "rows" => [%{"label" => "revenue"}]}
      assert {:error, "ERROR duplicate_label: " <> _} = Rows.add_rows(args, context)

      args = %{
        "sheet_id" => sheet.id,
        "rows" => [%{"label" => "Tax", "values" => %{"Q1" => "lots"}}]
      }

      assert {:error, "ERROR invalid_value: " <> _} = Rows.add_rows(args, context)

      args = %{"sheet_id" => sheet.id, "rows" => [%{"label" => "Tax", "values" => %{"Q3" => 1}}]}
      assert {:error, text} = Rows.add_rows(args, context)
      assert text =~ ~s(ERROR unknown_column: column "Q3" does not exist)
      assert text =~ "Existing columns: Line item, Q1, Q2."

      # The test config caps an op at 50 rows.
      rows = for i <- 1..51, do: %{"label" => "Row #{i}"}

      assert {:error, "ERROR too_many_cells: " <> _} =
               Rows.add_rows(%{"sheet_id" => sheet.id, "rows" => rows}, context)

      assert {:error, "ERROR unknown_row: " <> _} =
               Rows.delete_rows(%{"sheet_id" => sheet.id, "labels" => ["Tax"]}, context)

      assert {:error, "ERROR invalid_arguments: " <> _} =
               Rows.add_rows(%{"sheet_id" => sheet.id, "rows" => ["Tax"]}, context)

      assert {:error, "ERROR invalid_arguments: " <> _} =
               Rows.delete_rows(%{"sheet_id" => sheet.id, "labels" => []}, context)

      refute_receive {:op_applied, _}
      assert labels(sheet.id) == ["Revenue", "Payroll"]
      assert_not_linked(context)
    end
  end

  describe "set_cells" do
    test "sets many cells in one op, including a label and a clear", %{
      sheet: sheet,
      context: context
    } do
      args = %{
        "sheet_id" => sheet.id,
        "cells" => [
          %{"row" => "Revenue", "column" => "Q2", "value" => 1300},
          %{"row" => "Payroll", "column" => "Q1", "value" => nil},
          %{"row" => "Payroll", "column" => "Line item", "value" => "Salaries"}
        ]
      }

      assert {:ok, json} = Cells.set_cells(args, context)
      assert Jason.decode!(json) == %{"version" => 2, "updated" => 3}
      assert_receive {:op_applied, %{version: 2, applied_op: %{"type" => "set_cells"}}}

      assert {:ok, cells} = Sheets.read_cells(sheet.id, ["Revenue", "Salaries"], ["Q1", "Q2"])

      assert cells == %{
               "Revenue" => %{"Q1" => 1200, "Q2" => 1300},
               "Salaries" => %{"Q1" => nil, "Q2" => nil}
             }

      assert_written(sheet.id, context)
    end

    test "one bad cell rejects them all", %{sheet: sheet, context: context} do
      args = %{
        "sheet_id" => sheet.id,
        "cells" => [
          %{"row" => "Revenue", "column" => "Q2", "value" => 1300},
          %{"row" => "Revenue", "column" => "Q1", "value" => "n/a"}
        ]
      }

      assert {:error, "ERROR invalid_value: " <> _} = Cells.set_cells(args, context)

      args = %{
        "sheet_id" => sheet.id,
        "cells" => [%{"row" => "Revenue", "column" => "Q2"}]
      }

      assert {:error, text} = Cells.set_cells(args, context)
      assert text =~ ~s(ERROR invalid_op: each cell needs "row", "column" and "value")

      assert {:error, "ERROR invalid_arguments: " <> _} =
               Cells.set_cells(%{"sheet_id" => sheet.id, "cells" => %{}}, context)

      refute_receive {:op_applied, _}
      assert {:ok, %{version: 1}} = Sheets.describe(sheet.id)
      assert_not_linked(context)
    end
  end

  defp labels(sheet_id) do
    {:ok, %{rows: labels}} = Sheets.find_rows(sheet_id, "")
    labels
  end

  defp assert_written(sheet_id, context) do
    assert_receive {:focus_sheet, ^sheet_id, :written}
    assert_receive {:sheets_changed}

    assert [%{sheet: %{id: ^sheet_id}, last_access: "written"}] =
             Sheets.list_links(context.conversation_id)
  end

  defp assert_not_linked(context) do
    refute_receive {:focus_sheet, _, _}
    assert Sheets.list_links(context.conversation_id) == []
  end
end
