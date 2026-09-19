defmodule SpreadSheetAi.Sheets.EngineTest do
  use ExUnit.Case, async: true

  import SpreadSheetAi.EngineHelpers

  alias SpreadSheetAi.Sheets.{Engine, Key, Op, State}

  # Revenue: Q1 100, Q2 120 · Costs: Q1 40 · Profit: empty
  setup do
    state =
      state!(%{
        "columns" => [
          %{"name" => "Q1", "column_type" => "number"},
          %{"name" => "Q2", "column_type" => "number"},
          %{"name" => "Notes", "column_type" => "text"}
        ],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 100, "Q2" => 120}},
          %{"label" => "Costs", "values" => %{"Q1" => 40}},
          %{"label" => "Profit"}
        ]
      })

    %{state: state}
  end

  defp op(type, fields), do: Map.put(fields, "type", type)

  defp set_cells(cells) do
    op("set_cells", %{
      "cells" =>
        Enum.map(cells, fn {row_id, column_id, value} ->
          %{"row_id" => row_id, "column_id" => column_id, "value" => value}
        end)
    })
  end

  describe "create/3 (T-1, T-4)" do
    test "builds a sheet at version 1 with the label column first", %{state: state} do
      assert state.version == 1
      assert state.name == "P&L 2026"
      assert column_names(state) == ["Line item", "Q1", "Q2", "Notes"]
      assert [%{is_label: true, column_type: "text"} | _] = State.columns(state)
      assert labels(state) == ["Revenue", "Costs", "Profit"]
      assert cells(state, "Revenue") == %{"Line item" => "Revenue", "Q1" => 100, "Q2" => 120}
    end

    test "returns the create_sheet op and the insert effects" do
      owner_id = Ecto.UUID.generate()

      {:ok, op} =
        Op.parse_create(%{
          "name" => "  Budget ",
          "label_column_name" => " Item ",
          "columns" => [%{"name" => "Q1", "column_type" => "number"}],
          "rows" => [%{"label" => " Revenue ", "values" => %{"q1" => 12.0}}]
        })

      assert {:ok, state, applied, effects} = Engine.create(op, owner_id, limits())
      assert_consistent(state)
      [label_id, q1_id] = state.column_order
      [row_id] = state.row_order

      assert applied == %{
               "type" => "create_sheet",
               "name" => "Budget",
               "columns" => [
                 %{
                   "id" => label_id,
                   "name" => "Item",
                   "column_type" => "text",
                   "is_label" => true
                 },
                 %{"id" => q1_id, "name" => "Q1", "column_type" => "number", "is_label" => false}
               ],
               "rows" => [%{"id" => row_id, "cells" => %{label_id => "Revenue", q1_id => 12}}]
             }

      assert [
               {:insert_sheet, %{id: sheet_id, name: "Budget", owner_id: ^owner_id, version: 1}},
               {:insert_columns,
                [
                  %{id: ^label_id, name: "Item", name_key: "item", is_label: true, position: 0},
                  %{id: ^q1_id, name: "Q1", name_key: "q1", column_type: "number", position: 1}
                ]},
               {:insert_rows,
                [
                  %{id: ^row_id, label: "Revenue", label_key: "revenue", position: 0, values: %{}} =
                    row
                ]}
             ] = effects

      assert sheet_id == state.id
      assert row.values == %{q1_id => 12}
    end

    test "a sheet without rows has no insert_rows effect" do
      {:ok, op} = Op.parse_create(%{"name" => "Empty"})
      assert {:ok, state, _applied, effects} = Engine.create(op, Ecto.UUID.generate(), limits())
      assert column_names(state) == ["Line item"]
      assert Enum.map(effects, &elem(&1, 0)) == [:insert_sheet, :insert_columns]
    end

    test "rejects invalid sheets" do
      for {params, code} <- [
            {%{"name" => "   "}, :validation_failed},
            {%{"name" => "B", "label_column_name" => " "}, :validation_failed},
            {%{"name" => "B", "columns" => [%{"name" => " ", "column_type" => "text"}]},
             :validation_failed},
            {%{"name" => "B", "columns" => [%{"name" => "line ITEM", "column_type" => "text"}]},
             :duplicate_column_name},
            {%{
               "name" => "B",
               "columns" => [
                 %{"name" => "Q1", "column_type" => "number"},
                 %{"name" => "q1", "column_type" => "text"}
               ]
             }, :duplicate_column_name},
            {%{"name" => "B", "rows" => [%{"label" => "R", "values" => %{"Q9" => 1}}]},
             :unknown_column},
            {%{"name" => "B", "rows" => [%{"label" => "R"}, %{"label" => " r "}]},
             :duplicate_label},
            {%{"name" => "B", "rows" => [%{}]}, :label_required},
            {%{
               "name" => "B",
               "columns" => [%{"name" => "Q1", "column_type" => "number"}],
               "rows" => [%{"label" => "R", "values" => %{"Q1" => "ten"}}]
             }, :invalid_value},
            {%{"name" => "B", "rows" => Enum.map(1..6, &%{"label" => "R#{&1}"})}, :too_many_cells}
          ] do
        {:ok, op} = Op.parse_create(params)

        assert {:error, ^code, message, _meta} = Engine.create(op, Ecto.UUID.generate(), limits()),
               inspect(params)

        assert is_binary(message)
      end
    end
  end

  describe "rename_sheet" do
    test "trims the name", %{state: state} do
      {state, applied, effects} = apply!(state, op("rename_sheet", %{"name" => "  Budget  "}))
      assert state.name == "Budget"
      assert applied == %{"type" => "rename_sheet", "name" => "Budget"}
      assert effects == [{:update_sheet, %{name: "Budget"}}]
    end

    test "rejects a blank name", %{state: state} do
      assert {:invalid_op, "sheet name can't be blank", _} =
               apply_error(state, op("rename_sheet", %{"name" => "  "}))
    end
  end

  describe "add_column (T-2)" do
    test "appends by default and keeps a client id", %{state: state} do
      id = Ecto.UUID.generate()

      {state, applied, effects} =
        apply!(
          state,
          op("add_column", %{"id" => id, "name" => " Q3 ", "column_type" => "number"})
        )

      assert column_names(state) == ["Line item", "Q1", "Q2", "Notes", "Q3"]

      assert applied == %{
               "type" => "add_column",
               "id" => id,
               "name" => "Q3",
               "column_type" => "number",
               "position" => 4
             }

      assert effects == [
               {:insert_column,
                %{
                  id: id,
                  name: "Q3",
                  name_key: "q3",
                  column_type: "number",
                  is_label: false,
                  position: 4
                }}
             ]
    end

    test "inserts at a position and renumbers only the columns after it", %{state: state} do
      [_label, q1, q2, notes] = state.column_order

      {state, %{"id" => id}, effects} =
        apply!(
          state,
          op("add_column", %{"name" => "Q0", "column_type" => "date", "position" => 1})
        )

      assert {:ok, _} = Ecto.UUID.cast(id)
      assert column_names(state) == ["Line item", "Q0", "Q1", "Q2", "Notes"]
      assert [{:insert_column, %{position: 1}}, {:set_positions, :columns, moved}] = effects
      assert moved == [{q1, 2}, {q2, 3}, {notes, 4}]
    end

    test "accepts position == length and rejects length + 1", %{state: state} do
      apply!(state, op("add_column", %{"name" => "Q3", "column_type" => "text", "position" => 4}))

      assert {:invalid_position, _, %{position: 5, max: 4}} =
               apply_error(
                 state,
                 op("add_column", %{"name" => "Q3", "column_type" => "text", "position" => 5})
               )
    end

    test "rejects a duplicate name, trimmed and case-insensitive (OP-2)", %{state: state} do
      assert {:duplicate_column_name, message, %{name: "q1"}} =
               apply_error(state, op("add_column", %{"name" => " q1 ", "column_type" => "text"}))

      assert message =~ ~s("q1")
    end

    test "rejects a blank name and an id already in use", %{state: state} do
      assert {:invalid_op, _, _} =
               apply_error(state, op("add_column", %{"name" => " ", "column_type" => "text"}))

      assert {:invalid_op, message, _} =
               apply_error(
                 state,
                 op("add_column", %{
                   "id" => column_id(state, "Q1"),
                   "name" => "Q3",
                   "column_type" => "text"
                 })
               )

      assert message =~ "already in use"
    end
  end

  describe "rename_column" do
    test "renames without changing the id (T-6)", %{state: state} do
      q1 = column_id(state, "Q1")

      {state, applied, effects} =
        apply!(state, op("rename_column", %{"column_id" => q1, "name" => "Jan"}))

      assert column_id(state, "Jan") == q1
      assert State.fetch_column_by_name(state, "Q1") == :error
      assert applied == %{"type" => "rename_column", "column_id" => q1, "name" => "Jan"}
      assert effects == [{:update_column, q1, %{name: "Jan", name_key: "jan"}}]
    end

    test "allows a case-only rename of the same column and renaming the label column", %{
      state: state
    } do
      {state, _, _} =
        apply!(
          state,
          op("rename_column", %{"column_id" => column_id(state, "Q1"), "name" => "q1"})
        )

      {state, _, _} =
        apply!(
          state,
          op("rename_column", %{"column_id" => state.label_column_id, "name" => "Item"})
        )

      assert column_names(state) == ["Item", "q1", "Q2", "Notes"]
    end

    test "rejects another column's name and an unknown column", %{state: state} do
      assert {:duplicate_column_name, _, _} =
               apply_error(
                 state,
                 op("rename_column", %{"column_id" => column_id(state, "Q1"), "name" => "Q2"})
               )

      unknown = Ecto.UUID.generate()

      assert {:unknown_column, _, %{column_id: ^unknown}} =
               apply_error(state, op("rename_column", %{"column_id" => unknown, "name" => "X"}))
    end
  end

  describe "change_column_type" do
    test "converts every value and reports the converted cells", %{state: state} do
      q1 = column_id(state, "Q1")
      revenue = row_id(state, "Revenue")
      costs = row_id(state, "Costs")

      {state, applied, effects} =
        apply!(state, op("change_column_type", %{"column_id" => q1, "column_type" => "text"}))

      assert cells(state, "Revenue")["Q1"] == "100"

      assert applied == %{
               "type" => "change_column_type",
               "column_id" => q1,
               "column_type" => "text",
               "cells" => [
                 %{"row_id" => revenue, "value" => "100"},
                 %{"row_id" => costs, "value" => "40"}
               ]
             }

      assert [
               {:update_column, ^q1, %{column_type: "text"}},
               {:update_row, ^revenue, %{values: v1}},
               {:update_row, ^costs, _}
             ] =
               effects

      assert v1[q1] == "100"
    end

    test "blank text becomes empty and is reported as null", %{state: state} do
      notes = column_id(state, "Notes")
      profit = row_id(state, "Profit")
      {state, _, _} = apply!(state, set_cells([{profit, notes, "   "}]))

      {state, applied, _} =
        apply!(
          state,
          op("change_column_type", %{"column_id" => notes, "column_type" => "number"})
        )

      assert applied["cells"] == [%{"row_id" => profit, "value" => nil}]
      refute Map.has_key?(cells(state, "Profit"), "Notes")
    end

    test "fails on the first value that can't be converted (OP-1)", %{state: state} do
      notes = column_id(state, "Notes")
      costs = row_id(state, "Costs")
      profit = row_id(state, "Profit")
      {state, _, _} = apply!(state, set_cells([{costs, notes, "12"}, {profit, notes, "n/a"}]))

      assert {:type_conversion_failed, message, %{row_id: ^profit}} =
               apply_error(
                 state,
                 op("change_column_type", %{"column_id" => notes, "column_type" => "number"})
               )

      assert message =~ ~s("Profit")
    end

    test "the same type is accepted without row effects", %{state: state} do
      q1 = column_id(state, "Q1")

      {_state, _applied, effects} =
        apply!(state, op("change_column_type", %{"column_id" => q1, "column_type" => "number"}))

      assert effects == [{:update_column, q1, %{column_type: "number"}}]
    end

    test "the label column can't be retyped (T-4)", %{state: state} do
      assert {:label_column_protected, _, _} =
               apply_error(
                 state,
                 op("change_column_type", %{
                   "column_id" => state.label_column_id,
                   "column_type" => "number"
                 })
               )
    end
  end

  describe "move_column" do
    test "moves to a final index and renumbers only what moved", %{state: state} do
      [label, q1, q2, notes] = state.column_order

      {state, applied, effects} =
        apply!(state, op("move_column", %{"column_id" => label, "position" => 3}))

      assert column_names(state) == ["Q1", "Q2", "Notes", "Line item"]
      assert applied == %{"type" => "move_column", "column_id" => label, "position" => 3}
      assert effects == [{:set_positions, :columns, [{q1, 0}, {q2, 1}, {notes, 2}, {label, 3}]}]
    end

    test "moving to the current position is accepted with no effects", %{state: state} do
      assert {_state, _, []} =
               apply!(
                 state,
                 op("move_column", %{"column_id" => column_id(state, "Q2"), "position" => 2})
               )
    end

    test "positions are 0..length-1", %{state: state} do
      q1 = column_id(state, "Q1")
      apply!(state, op("move_column", %{"column_id" => q1, "position" => 0}))

      assert {:invalid_position, _, %{max: 3}} =
               apply_error(state, op("move_column", %{"column_id" => q1, "position" => 4}))
    end
  end

  describe "delete_column" do
    test "removes the column and its values", %{state: state} do
      q1 = column_id(state, "Q1")
      [_label, _q1, q2, notes] = state.column_order

      {state, applied, effects} = apply!(state, op("delete_column", %{"column_id" => q1}))

      assert column_names(state) == ["Line item", "Q2", "Notes"]
      assert cells(state, "Revenue") == %{"Line item" => "Revenue", "Q2" => 120}
      assert applied == %{"type" => "delete_column", "column_id" => q1}

      assert effects == [
               {:delete_column, q1},
               {:remove_column_values, q1},
               {:set_positions, :columns, [{q2, 1}, {notes, 2}]}
             ]

      # The name is free again.
      apply!(state, op("add_column", %{"name" => "Q1", "column_type" => "number"}))
    end

    test "the label column can't be deleted (T-4)", %{state: state} do
      assert {:label_column_protected, message, _} =
               apply_error(state, op("delete_column", %{"column_id" => state.label_column_id}))

      assert message =~ "Line item"
    end
  end

  describe "add_rows (T-5, T-7)" do
    test "appends rows with cast values and trimmed labels", %{state: state} do
      id = Ecto.UUID.generate()
      label = state.label_column_id
      q1 = column_id(state, "Q1")
      notes = column_id(state, "Notes")

      {state, applied, effects} =
        apply!(
          state,
          op("add_rows", %{
            "rows" => [%{"id" => id, "cells" => %{label => " Tax ", q1 => 5.0, notes => ""}}]
          })
        )

      assert labels(state) == ["Revenue", "Costs", "Profit", "Tax"]

      assert applied == %{
               "type" => "add_rows",
               "position" => 3,
               "rows" => [%{"id" => id, "cells" => %{label => "Tax", q1 => 5}}]
             }

      assert effects == [
               {:insert_rows,
                [%{id: id, label: "Tax", label_key: "tax", position: 3, values: %{q1 => 5}}]}
             ]
    end

    test "inserts at a position and renumbers the rows after it", %{state: state} do
      [revenue, costs, profit] = state.row_order

      {state, %{"rows" => [%{"id" => new_id}]}, effects} =
        apply!(
          state,
          op("add_rows", %{
            "position" => 1,
            "rows" => [%{"cells" => %{state.label_column_id => "Tax"}}]
          })
        )

      assert labels(state) == ["Revenue", "Tax", "Costs", "Profit"]

      assert [{:insert_rows, [%{id: ^new_id, position: 1}]}, {:set_positions, :rows, moved}] =
               effects

      assert moved == [{costs, 2}, {profit, 3}]
      assert revenue == hd(state.row_order)
    end

    test "labels are required", %{state: state} do
      for cells <- [%{}, %{state.label_column_id => nil}, %{state.label_column_id => "   "}] do
        assert {:label_required, _, %{row_id: _}} =
                 apply_error(state, op("add_rows", %{"rows" => [%{"cells" => cells}]}))
      end

      assert {:invalid_value, _, _} =
               apply_error(
                 state,
                 op("add_rows", %{"rows" => [%{"cells" => %{state.label_column_id => 12}}]})
               )
    end

    test "labels are unique against the sheet and the batch, trimmed and case-insensitive", %{
      state: state
    } do
      label = state.label_column_id

      assert {:duplicate_label, message, %{label: "revenue"}} =
               apply_error(
                 state,
                 op("add_rows", %{"rows" => [%{"cells" => %{label => " revenue "}}]})
               )

      assert message =~ ~s("revenue")

      assert {:duplicate_label, _, _} =
               apply_error(
                 state,
                 op("add_rows", %{
                   "rows" => [%{"cells" => %{label => "Tax"}}, %{"cells" => %{label => "TAX"}}]
                 })
               )
    end

    test "rejects unknown columns, invalid values, used ids and bad positions", %{state: state} do
      label = state.label_column_id
      q1 = column_id(state, "Q1")
      id = Ecto.UUID.generate()

      assert {:unknown_column, _, _} =
               apply_error(
                 state,
                 op("add_rows", %{
                   "rows" => [%{"cells" => %{label => "Tax", Ecto.UUID.generate() => 1}}]
                 })
               )

      assert {:invalid_value, _, %{row_id: ^id, column_id: ^q1}} =
               apply_error(
                 state,
                 op("add_rows", %{
                   "rows" => [%{"id" => id, "cells" => %{label => "Tax", q1 => "5"}}]
                 })
               )

      assert {:invalid_op, _, _} =
               apply_error(
                 state,
                 op("add_rows", %{
                   "rows" => [%{"id" => row_id(state, "Costs"), "cells" => %{label => "Tax"}}]
                 })
               )

      assert {:invalid_position, _, %{max: 3}} =
               apply_error(
                 state,
                 op("add_rows", %{"position" => 4, "rows" => [%{"cells" => %{label => "Tax"}}]})
               )
    end

    test "accepts exactly the cap and rejects one more", %{state: state} do
      rows = fn n -> Enum.map(1..n, &%{"cells" => %{state.label_column_id => "Row #{&1}"}}) end

      apply!(state, op("add_rows", %{"rows" => rows.(5)}))

      assert {:too_many_cells, _, %{max: 5}} =
               apply_error(state, op("add_rows", %{"rows" => rows.(6)}))
    end
  end

  describe "delete_rows" do
    test "removes rows and frees their labels", %{state: state} do
      [revenue, costs, profit] = state.row_order

      {state, applied, effects} = apply!(state, op("delete_rows", %{"row_ids" => [revenue]}))

      assert labels(state) == ["Costs", "Profit"]
      assert applied == %{"type" => "delete_rows", "row_ids" => [revenue]}

      assert effects == [
               {:delete_rows, [revenue]},
               {:set_positions, :rows, [{costs, 0}, {profit, 1}]}
             ]

      apply!(
        state,
        op("add_rows", %{"rows" => [%{"cells" => %{state.label_column_id => "Revenue"}}]})
      )
    end

    test "rejects an unknown row and leaves the rest alone (OP-1)", %{state: state} do
      unknown = Ecto.UUID.generate()

      assert {:unknown_row, _, %{row_id: ^unknown}} =
               apply_error(
                 state,
                 op("delete_rows", %{"row_ids" => [row_id(state, "Costs"), unknown]})
               )
    end
  end

  describe "move_row (T-6)" do
    test "moves to a final index without changing ids", %{state: state} do
      [revenue, costs, profit] = state.row_order

      {state, applied, effects} =
        apply!(state, op("move_row", %{"row_id" => profit, "position" => 0}))

      assert labels(state) == ["Profit", "Revenue", "Costs"]
      assert row_id(state, "Profit") == profit
      assert applied == %{"type" => "move_row", "row_id" => profit, "position" => 0}
      assert effects == [{:set_positions, :rows, [{profit, 0}, {revenue, 1}, {costs, 2}]}]
    end

    test "positions are 0..length-1", %{state: state} do
      revenue = row_id(state, "Revenue")
      apply!(state, op("move_row", %{"row_id" => revenue, "position" => 2}))

      assert {:invalid_position, _, %{max: 2}} =
               apply_error(state, op("move_row", %{"row_id" => revenue, "position" => 3}))

      assert {:invalid_position, _, _} =
               apply_error(state, op("move_row", %{"row_id" => revenue, "position" => -1}))

      assert {:unknown_row, _, _} =
               apply_error(
                 state,
                 op("move_row", %{"row_id" => Ecto.UUID.generate(), "position" => 0})
               )
    end
  end

  describe "set_cells" do
    test "sets and clears values with one effect per row", %{state: state} do
      revenue = row_id(state, "Revenue")
      costs = row_id(state, "Costs")
      q1 = column_id(state, "Q1")
      q2 = column_id(state, "Q2")

      {state, applied, effects} =
        apply!(state, set_cells([{revenue, q1, 150.0}, {revenue, q2, nil}, {costs, q2, 45}]))

      assert cells(state, "Revenue") == %{"Line item" => "Revenue", "Q1" => 150}
      assert cells(state, "Costs")["Q2"] == 45

      assert applied == %{
               "type" => "set_cells",
               "cells" => [
                 %{"row_id" => revenue, "column_id" => q1, "value" => 150},
                 %{"row_id" => revenue, "column_id" => q2, "value" => nil},
                 %{"row_id" => costs, "column_id" => q2, "value" => 45}
               ]
             }

      assert effects == [
               {:update_row, revenue, %{values: %{q1 => 150}}},
               {:update_row, costs, %{values: %{q1 => 40, q2 => 45}}}
             ]
    end

    test "setting the label cell renames the row", %{state: state} do
      revenue = row_id(state, "Revenue")

      {state, applied, effects} =
        apply!(state, set_cells([{revenue, state.label_column_id, " Sales "}]))

      assert row_id(state, "Sales") == revenue
      assert [%{"value" => "Sales"}] = applied["cells"]
      assert effects == [{:update_row, revenue, %{label: "Sales", label_key: "sales"}}]
    end

    test "label rules apply to the label cell (T-5)", %{state: state} do
      revenue = row_id(state, "Revenue")
      label = state.label_column_id

      assert {:label_required, _, %{row_id: ^revenue}} =
               apply_error(state, set_cells([{revenue, label, nil}]))

      assert {:label_required, _, _} = apply_error(state, set_cells([{revenue, label, " "}]))

      assert {:duplicate_label, _, %{label: "COSTS"}} =
               apply_error(state, set_cells([{revenue, label, "COSTS"}]))

      # A case-only rename of the same row is fine.
      {state, _, _} = apply!(state, set_cells([{revenue, label, "REVENUE"}]))
      assert labels(state) == ["REVENUE", "Costs", "Profit"]
    end

    test "labels are checked on their final values, so swaps work", %{state: state} do
      revenue = row_id(state, "Revenue")
      costs = row_id(state, "Costs")
      profit = row_id(state, "Profit")
      label = state.label_column_id

      {swapped, _, _} =
        apply!(state, set_cells([{revenue, label, "Costs"}, {costs, label, "Revenue"}]))

      assert labels(swapped) == ["Costs", "Revenue", "Profit"]
      assert row_id(swapped, "Costs") == revenue

      # A label freed earlier in the same op can be reused.
      {state, _, _} =
        apply!(state, set_cells([{revenue, label, "Sales"}, {costs, label, "Revenue"}]))

      assert labels(state) == ["Sales", "Revenue", "Profit"]

      assert {:duplicate_label, _, _} =
               apply_error(state, set_cells([{costs, label, "Tax"}, {profit, label, "tax"}]))
    end

    test "rejects invalid values, unknown rows and unknown columns", %{state: state} do
      revenue = row_id(state, "Revenue")
      q1 = column_id(state, "Q1")

      assert {:invalid_value, message, %{row_id: ^revenue, column_id: ^q1}} =
               apply_error(state, set_cells([{revenue, q1, "lots"}]))

      assert message =~ ~s("Q1") and message =~ ~s("Revenue")

      assert {:unknown_row, _, _} = apply_error(state, set_cells([{Ecto.UUID.generate(), q1, 1}]))

      assert {:unknown_column, _, _} =
               apply_error(state, set_cells([{revenue, Ecto.UUID.generate(), 1}]))
    end

    test "one bad cell rejects the whole op and the state is unchanged (OP-1)", %{state: state} do
      [_label | value_columns] = state.column_order
      notes = column_id(state, "Notes")
      profit = row_id(state, "Profit")

      valid =
        for row <- state.row_order, column <- value_columns do
          {row, column, if(column == notes, do: "ok", else: 1)}
        end

      assert length(valid) == 9
      op = set_cells(valid ++ [{profit, state.label_column_id, 12}])

      assert {:invalid_value, _, %{row_id: ^profit}} =
               apply_error(state, op, %{write_max_cells: 100})

      assert cells(state, "Revenue") == %{"Line item" => "Revenue", "Q1" => 100, "Q2" => 120}
      assert state.version == 1
    end

    test "the last write to a cell wins across ops (OP-4)", %{state: state} do
      revenue = row_id(state, "Revenue")
      q1 = column_id(state, "Q1")

      {state, _, _} = apply!(state, set_cells([{revenue, q1, 1}]))
      {state, _, _} = apply!(state, set_cells([{revenue, q1, 2}]))

      assert cells(state, "Revenue")["Q1"] == 2
      assert state.version == 3
    end

    test "setting a cell to its current value has no effect but bumps the version", %{
      state: state
    } do
      {state, _, effects} =
        apply!(state, set_cells([{row_id(state, "Revenue"), column_id(state, "Q1"), 100}]))

      assert effects == []
      assert state.version == 2
    end

    test "accepts exactly the cap and rejects one more (T-7)", %{state: state} do
      q1 = column_id(state, "Q1")
      q2 = column_id(state, "Q2")
      [revenue, costs, profit] = state.row_order
      cells = for row <- [revenue, costs, profit], column <- [q1, q2], do: {row, column, 1}

      apply!(state, set_cells(Enum.take(cells, 5)))
      assert {:too_many_cells, _, %{max: 5}} = apply_error(state, set_cells(cells))
    end
  end

  test "keys are normalized the same way as the database" do
    assert Key.normalize("  Q1 ") == "q1"
  end
end
