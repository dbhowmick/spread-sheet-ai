defmodule SpreadSheetAi.Sheets.NamedTest do
  use ExUnit.Case, async: true

  import SpreadSheetAi.EngineHelpers

  alias SpreadSheetAi.Sheets.{Named, Op}

  setup do
    state =
      state!(%{
        "columns" => [
          %{"name" => "Q1", "column_type" => "number"},
          %{"name" => "Note", "column_type" => "text"}
        ],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200}},
          %{"label" => "Payroll", "values" => %{}}
        ]
      })

    %{state: state, label_id: state.label_column_id}
  end

  describe "resolves names to ids" do
    test "sheet and new-column ops need no names", %{state: state} do
      assert Named.resolve(state, %{"type" => "rename_sheet", "name" => "P&L"}) ==
               {:ok, %Op.RenameSheet{name: "P&L"}}

      assert Named.resolve(state, %{
               "type" => "add_column",
               "name" => "Q2",
               "column_type" => "number",
               "position" => 2
             }) == {:ok, %Op.AddColumn{name: "Q2", column_type: "number", position: 2}}
    end

    test "column ops, case-insensitively", %{state: state} do
      q1 = column_id(state, "Q1")

      assert Named.resolve(state, %{
               "type" => "rename_column",
               "column" => " q1 ",
               "name" => "Jan"
             }) ==
               {:ok, %Op.RenameColumn{column_id: q1, name: "Jan"}}

      assert Named.resolve(state, %{
               "type" => "change_column_type",
               "column" => "Q1",
               "column_type" => "text"
             }) == {:ok, %Op.ChangeColumnType{column_id: q1, column_type: "text"}}

      assert Named.resolve(state, %{"type" => "move_column", "column" => "Q1", "position" => 2}) ==
               {:ok, %Op.MoveColumn{column_id: q1, position: 2}}

      assert Named.resolve(state, %{"type" => "delete_column", "column" => "Q1"}) ==
               {:ok, %Op.DeleteColumn{column_id: q1}}
    end

    test "add_rows puts the label in the label column", %{state: state, label_id: label_id} do
      q1 = column_id(state, "Q1")

      assert {:ok, %Op.AddRows{rows: [row], position: 1}} =
               Named.resolve(state, %{
                 "type" => "add_rows",
                 "rows" => [%{"label" => "Rent", "values" => %{"q1" => 90}}],
                 "position" => 1
               })

      assert row == %{id: nil, cells: %{label_id => "Rent", q1 => 90}}

      assert {:ok, %Op.AddRows{rows: [%{cells: cells}]}} =
               Named.resolve(state, %{"type" => "add_rows", "rows" => [%{"label" => "Tax"}]})

      assert cells == %{label_id => "Tax"}
    end

    test "row ops by label", %{state: state} do
      revenue = row_id(state, "Revenue")
      payroll = row_id(state, "Payroll")

      assert Named.resolve(state, %{"type" => "delete_rows", "labels" => ["payroll", "Revenue"]}) ==
               {:ok, %Op.DeleteRows{row_ids: [payroll, revenue]}}

      assert Named.resolve(state, %{"type" => "move_row", "label" => "Payroll", "position" => 0}) ==
               {:ok, %Op.MoveRow{row_id: payroll, position: 0}}
    end

    test "set_cells, including the label column and nulls", %{state: state, label_id: label_id} do
      revenue = row_id(state, "Revenue")
      q1 = column_id(state, "Q1")

      assert Named.resolve(state, %{
               "type" => "set_cells",
               "cells" => [
                 %{"row" => "Revenue", "column" => "Q1", "value" => nil},
                 %{"row" => "Revenue", "column" => "Line item", "value" => "Sales"}
               ]
             }) ==
               {:ok,
                %Op.SetCells{
                  cells: [
                    %{row_id: revenue, column_id: q1, value: nil},
                    %{row_id: revenue, column_id: label_id, value: "Sales"}
                  ]
                }}
    end
  end

  describe "errors" do
    test "unknown names are reported by name", %{state: state} do
      assert {:error, :unknown_column, ~s(column "Q3" does not exist in sheet "P&L 2026"),
              %{column: "Q3"}} =
               Named.resolve(state, %{"type" => "delete_column", "column" => "Q3"})

      assert {:error, :unknown_row, ~s(row "Tax" does not exist in sheet "P&L 2026"),
              %{label: "Tax"}} =
               Named.resolve(state, %{
                 "type" => "set_cells",
                 "cells" => [%{"row" => "Tax", "column" => "Q1", "value" => 1}]
               })

      assert {:error, :unknown_column, _, %{column: "Q9"}} =
               Named.resolve(state, %{
                 "type" => "add_rows",
                 "rows" => [%{"label" => "Tax", "values" => %{"Q9" => 1}}]
               })
    end

    test "duplicates are reported by name", %{state: state} do
      assert {:error, :invalid_op, ~s(row "Revenue" is listed twice), _} =
               Named.resolve(state, %{"type" => "delete_rows", "labels" => ["Revenue", "revenue"]})

      assert {:error, :invalid_op, ~s(cell "Revenue" / "Q1" is set twice), _} =
               Named.resolve(state, %{
                 "type" => "set_cells",
                 "cells" => [
                   %{"row" => "Revenue", "column" => "Q1", "value" => 1},
                   %{"row" => "revenue", "column" => "q1", "value" => 2}
                 ]
               })

      assert {:error, :invalid_op, ~s(column "Q1" is given twice in one row), _} =
               Named.resolve(state, %{
                 "type" => "add_rows",
                 "rows" => [%{"label" => "Tax", "values" => %{"Q1" => 1, "q1" => 2}}]
               })
    end

    test "the label belongs in label, not values", %{state: state} do
      assert {:error, :invalid_op, _, %{field: "rows"}} =
               Named.resolve(state, %{
                 "type" => "add_rows",
                 "rows" => [%{"label" => "Tax", "values" => %{"Line item" => "Tax"}}]
               })
    end

    test "malformed input is invalid_op, never a raise", %{state: state} do
      for op <- [
            nil,
            "set_cells",
            %{},
            %{"type" => 1},
            %{"type" => "explode"},
            %{"type" => "rename_column", "column" => 1, "name" => "x"},
            %{"type" => "rename_column", "column" => %{"a" => 1}, "name" => "x"},
            %{"type" => "rename_column", "column" => "Q1"},
            %{"type" => "move_column", "column" => "Q1", "position" => "1"},
            %{"type" => "delete_rows", "labels" => "Revenue"},
            %{"type" => "delete_rows", "labels" => []},
            %{"type" => "delete_rows", "labels" => [nil]},
            %{"type" => "move_row", "label" => ["Revenue"], "position" => 0},
            %{"type" => "add_rows", "rows" => ["Revenue"]},
            %{"type" => "add_rows", "rows" => [%{"label" => "Tax", "values" => [1]}]},
            %{"type" => "set_cells", "cells" => [%{"row" => "Revenue", "column" => "Q1"}]},
            %{"type" => "set_cells", "cells" => [["Revenue", "Q1", 1]]},
            %{"type" => "set_cells", "cells" => %{"row" => "Revenue"}}
          ] do
        assert {:error, :invalid_op, message, _meta} = Named.resolve(state, op),
               "expected invalid_op for #{inspect(op)}"

        assert is_binary(message)
      end
    end
  end
end
