defmodule SpreadSheetAi.Sheets.OpTest do
  use ExUnit.Case, async: true

  alias SpreadSheetAi.Sheets.Op

  @id Ecto.UUID.generate()
  @id2 Ecto.UUID.generate()

  describe "parse/1" do
    test "parses every op type into its struct" do
      for {map, expected} <- [
            {%{"type" => "rename_sheet", "name" => "Budget"}, %Op.RenameSheet{name: "Budget"}},
            {%{"type" => "add_column", "name" => "Q1", "column_type" => "number"},
             %Op.AddColumn{name: "Q1", column_type: "number"}},
            {%{
               "type" => "add_column",
               "id" => @id,
               "name" => "Q1",
               "column_type" => "date",
               "position" => 2
             }, %Op.AddColumn{id: @id, name: "Q1", column_type: "date", position: 2}},
            {%{"type" => "rename_column", "column_id" => @id, "name" => "Q2"},
             %Op.RenameColumn{column_id: @id, name: "Q2"}},
            {%{"type" => "change_column_type", "column_id" => @id, "column_type" => "text"},
             %Op.ChangeColumnType{column_id: @id, column_type: "text"}},
            {%{"type" => "move_column", "column_id" => @id, "position" => 0},
             %Op.MoveColumn{column_id: @id, position: 0}},
            {%{"type" => "delete_column", "column_id" => @id}, %Op.DeleteColumn{column_id: @id}},
            {%{
               "type" => "add_rows",
               "rows" => [%{"id" => @id, "cells" => %{@id2 => "Revenue"}}, %{}]
             },
             %Op.AddRows{rows: [%{id: @id, cells: %{@id2 => "Revenue"}}, %{id: nil, cells: %{}}]}},
            {%{"type" => "delete_rows", "row_ids" => [@id, @id2]},
             %Op.DeleteRows{row_ids: [@id, @id2]}},
            {%{"type" => "move_row", "row_id" => @id, "position" => 3},
             %Op.MoveRow{row_id: @id, position: 3}},
            {%{
               "type" => "set_cells",
               "cells" => [%{"row_id" => @id, "column_id" => @id2, "value" => nil}]
             }, %Op.SetCells{cells: [%{row_id: @id, column_id: @id2, value: nil}]}}
          ] do
        assert Op.parse(map) == {:ok, expected}
      end
    end

    test "rejects malformed ops with invalid_op" do
      for map <- [
            "rename_sheet",
            %{},
            %{"type" => 1},
            %{"type" => "drop_table"},
            %{"type" => "rename_sheet"},
            %{"type" => "rename_sheet", "name" => 12},
            %{"type" => "add_column", "name" => "Q1", "column_type" => "currency"},
            %{
              "type" => "add_column",
              "name" => "Q1",
              "column_type" => "number",
              "id" => "not-a-uuid"
            },
            %{
              "type" => "add_column",
              "name" => "Q1",
              "column_type" => "number",
              "position" => "1"
            },
            %{
              "type" => "add_column",
              "name" => "Q1",
              "column_type" => "number",
              "position" => 1.5
            },
            %{"type" => "rename_column", "column_id" => "nope", "name" => "Q1"},
            %{"type" => "move_column", "column_id" => @id},
            %{"type" => "add_rows", "rows" => []},
            %{"type" => "add_rows", "rows" => [1]},
            %{"type" => "add_rows", "rows" => [%{"cells" => []}]},
            %{"type" => "add_rows", "rows" => [%{"cells" => %{"Q1" => 1}}]},
            %{"type" => "add_rows", "rows" => [%{"id" => @id}, %{"id" => @id}]},
            %{"type" => "delete_rows", "row_ids" => []},
            %{"type" => "delete_rows", "row_ids" => [@id, @id]},
            %{"type" => "set_cells", "cells" => [%{"row_id" => @id, "column_id" => @id2}]},
            %{
              "type" => "set_cells",
              "cells" => [
                %{"row_id" => @id, "column_id" => @id2, "value" => 1},
                %{"row_id" => @id, "column_id" => @id2, "value" => 2}
              ]
            }
          ] do
        assert {:error, :invalid_op, message, _meta} = Op.parse(map), inspect(map)
        assert is_binary(message)
      end
    end

    test "a negative position is invalid_position" do
      assert {:error, :invalid_position, _, %{position: -1}} =
               Op.parse(%{"type" => "move_row", "row_id" => @id, "position" => -1})
    end

    test "never creates atoms from the op type" do
      assert {:error, :invalid_op, message, %{field: "type"}} =
               Op.parse(%{"type" => "surely_not_an_existing_atom_#{System.unique_integer()}"})

      assert message =~ "unknown op type"
    end
  end

  describe "parse_create/1" do
    test "fills in defaults" do
      assert {:ok,
              %Op.CreateSheet{
                name: "Budget",
                label_column_name: "Line item",
                columns: [],
                rows: []
              }} =
               Op.parse_create(%{"name" => "Budget"})
    end

    test "parses columns and rows" do
      assert {:ok, op} =
               Op.parse_create(%{
                 "name" => "Budget",
                 "label_column_name" => "Item",
                 "columns" => [%{"name" => "Q1", "column_type" => "number"}],
                 "rows" => [
                   %{"label" => "Revenue", "values" => %{"Q1" => 10}},
                   %{"label" => "Costs"}
                 ]
               })

      assert op.label_column_name == "Item"
      assert op.columns == [%{name: "Q1", column_type: "number"}]

      assert op.rows == [
               %{label: "Revenue", values: %{"Q1" => 10}},
               %{label: "Costs", values: %{}}
             ]
    end

    test "reports validation_failed with the field" do
      for {params, field} <- [
            {%{}, "name"},
            {%{"name" => 1}, "name"},
            {%{"name" => "B", "label_column_name" => 1}, "label_column_name"},
            {%{"name" => "B", "columns" => %{}}, "columns"},
            {%{"name" => "B", "columns" => [%{"name" => "Q1", "column_type" => "money"}]},
             "columns"},
            {%{"name" => "B", "columns" => [%{"column_type" => "number"}]}, "columns"},
            {%{"name" => "B", "rows" => [%{"label" => 1}]}, "rows"},
            {%{"name" => "B", "rows" => [%{"label" => "R", "values" => []}]}, "rows"}
          ] do
        assert {:error, :validation_failed, _message, %{field: ^field}} = Op.parse_create(params),
               inspect(params)
      end
    end
  end
end
