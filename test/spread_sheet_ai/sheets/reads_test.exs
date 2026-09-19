defmodule SpreadSheetAi.Sheets.ReadsTest do
  use ExUnit.Case, async: true

  import SpreadSheetAi.EngineHelpers

  alias SpreadSheetAi.Sheets.Reads

  setup do
    state =
      state!(%{
        "columns" => [
          %{"name" => "Q1", "column_type" => "number"},
          %{"name" => "Note", "column_type" => "text"}
        ],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200, "Note" => "up"}},
          %{"label" => "Cost of revenue", "values" => %{"Q1" => 400}},
          %{"label" => "Payroll", "values" => %{}},
          %{"label" => "Rent", "values" => %{"Q1" => 90}}
        ]
      })

    %{state: state}
  end

  test "describe/1 lists the structure without values", %{state: state} do
    assert Reads.describe(state) == %{
             id: state.id,
             name: "P&L 2026",
             version: 1,
             columns: [
               %{name: "Line item", column_type: "text", is_label: true},
               %{name: "Q1", column_type: "number", is_label: false},
               %{name: "Note", column_type: "text", is_label: false}
             ],
             row_count: 4
           }
  end

  describe "read_rows/3" do
    test "returns rows by label with every value column, empty cells as nil", %{state: state} do
      assert {:ok, %{rows: [revenue, cost | _], total: 4, offset: 0}} =
               Reads.read_rows(state, [], 10)

      assert revenue == %{label: "Revenue", values: %{"Q1" => 1200, "Note" => "up"}}
      assert cost == %{label: "Cost of revenue", values: %{"Q1" => 400, "Note" => nil}}
    end

    test "pages with offset and limit, capped at max", %{state: state} do
      assert {:ok, %{rows: rows, total: 4, offset: 1}} =
               Reads.read_rows(state, [offset: 1, limit: 2], 10)

      assert Enum.map(rows, & &1.label) == ["Cost of revenue", "Payroll"]

      assert {:ok, %{rows: rows}} = Reads.read_rows(state, [limit: 100], 3)
      assert length(rows) == 3

      assert {:ok, %{rows: [], total: 4}} = Reads.read_rows(state, [offset: 10], 10)
    end

    test "reads a subset of columns by name, case-insensitive", %{state: state} do
      assert {:ok, %{rows: [revenue | _]}} =
               Reads.read_rows(state, [columns: [" q1 ", "Line item"]], 10)

      assert revenue == %{label: "Revenue", values: %{"Q1" => 1200}}
    end

    test "rejects unknown columns and bad paging", %{state: state} do
      assert {:error, :unknown_column, message, %{column: "Q9"}} =
               Reads.read_rows(state, [columns: ["Q9"]], 10)

      assert message =~ ~s(column "Q9" does not exist in sheet "P&L 2026")

      assert {:error, :invalid_position, _, _} = Reads.read_rows(state, [offset: -1], 10)
      assert {:error, :invalid_op, _, _} = Reads.read_rows(state, [limit: 0], 10)
    end
  end

  describe "read_cells/4" do
    test "returns cells by label and column name", %{state: state} do
      assert Reads.read_cells(state, ["revenue", "Payroll"], ["Q1", "Note", "Line item"], 10) ==
               {:ok,
                %{
                  "Revenue" => %{"Q1" => 1200, "Note" => "up", "Line item" => "Revenue"},
                  "Payroll" => %{"Q1" => nil, "Note" => nil, "Line item" => "Payroll"}
                }}
    end

    test "names the unknown row or column", %{state: state} do
      assert {:error, :unknown_row, message, %{label: "Tax"}} =
               Reads.read_cells(state, ["Revenue", "Tax"], ["Q1"], 10)

      assert message =~ ~s(row "Tax")

      assert {:error, :unknown_column, _, %{column: "Q2"}} =
               Reads.read_cells(state, ["Revenue"], ["Q2"], 10)
    end

    test "caps the number of rows", %{state: state} do
      assert {:ok, _} = Reads.read_cells(state, ["Revenue", "Rent"], ["Q1"], 2)

      assert {:error, :too_many_cells, _, %{max: 1}} =
               Reads.read_cells(state, ["Revenue", "Rent"], ["Q1"], 1)
    end
  end

  describe "find_rows/3" do
    test "matches labels by substring, case-insensitive, in row order", %{state: state} do
      assert Reads.find_rows(state, " REVENUE", 10) ==
               %{rows: ["Revenue", "Cost of revenue"], truncated: false}

      assert Reads.find_rows(state, "tax", 10) == %{rows: [], truncated: false}
    end

    test "truncates at max", %{state: state} do
      assert Reads.find_rows(state, "e", 2) == %{
               rows: ["Revenue", "Cost of revenue"],
               truncated: true
             }

      assert Reads.find_rows(state, "revenue", 2) == %{
               rows: ["Revenue", "Cost of revenue"],
               truncated: false
             }
    end
  end
end
