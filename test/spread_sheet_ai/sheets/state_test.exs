defmodule SpreadSheetAi.Sheets.StateTest do
  use ExUnit.Case, async: true

  import SpreadSheetAi.EngineHelpers

  alias SpreadSheetAi.Sheets.{Column, Row, Sheet, State}

  describe "load/3" do
    test "orders columns and rows by position and builds the indexes" do
      sheet = %Sheet{
        id: Ecto.UUID.generate(),
        name: "Budget",
        owner_id: Ecto.UUID.generate(),
        version: 7
      }

      label = %Column{
        id: Ecto.UUID.generate(),
        name: "Line item",
        column_type: "text",
        is_label: true,
        position: 0
      }

      q1 = %Column{
        id: Ecto.UUID.generate(),
        name: "Q1",
        column_type: "number",
        is_label: false,
        position: 1
      }

      revenue = %Row{
        id: Ecto.UUID.generate(),
        label: "Revenue",
        position: 0,
        values: %{q1.id => 100}
      }

      costs = %Row{id: Ecto.UUID.generate(), label: "Costs", position: 1, values: %{}}

      state = State.load(sheet, [q1, label], [costs, revenue])

      assert_consistent(state)
      assert state.version == 7
      assert state.label_column_id == label.id
      assert column_names(state) == ["Line item", "Q1"]
      assert labels(state) == ["Revenue", "Costs"]
      assert cells(state, "revenue") == %{"Line item" => "Revenue", "Q1" => 100}
    end
  end

  describe "lookups" do
    setup do
      %{
        state:
          state!(%{
            "columns" => [%{"name" => "Q1", "column_type" => "number"}],
            "rows" => [%{"label" => "Revenue"}]
          })
      }
    end

    test "find columns and rows by name, trimmed and case-insensitive", %{state: state} do
      assert {:ok, %{name: "Q1"}} = State.fetch_column_by_name(state, " q1 ")
      assert {:ok, %{label: "Revenue"}} = State.fetch_row_by_label(state, "REVENUE")
      assert State.fetch_column_by_name(state, "Q9") == :error
      assert State.fetch_row_by_label(state, "Profit") == :error
    end
  end
end
