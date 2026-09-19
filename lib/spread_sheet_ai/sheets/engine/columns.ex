defmodule SpreadSheetAi.Sheets.Engine.Columns do
  @moduledoc false
  # Column ops: add, rename, change type, move, delete.

  alias SpreadSheetAi.Sheets.Engine.Checks
  alias SpreadSheetAi.Sheets.{Key, Op, State, Values}

  def add(state, %Op.AddColumn{} = op) do
    id = op.id || Ecto.UUID.generate()

    with {:ok, name} <- Checks.name(op.name, "column name"),
         :ok <- Checks.unique_column_name(state, name),
         :ok <- Checks.id_free(state.columns_by_id, id, "column"),
         {:ok, position} <- Checks.insert_position(op.position, length(state.column_order)) do
      column = %{id: id, name: name, column_type: op.column_type, is_label: false}
      new_state = State.insert_columns(state, [column], position)

      applied = %{
        "type" => "add_column",
        "id" => id,
        "name" => name,
        "column_type" => op.column_type,
        "position" => position
      }

      effects = [
        {:insert_column, Map.merge(column, %{name_key: Key.normalize(name), position: position})}
        | Checks.set_positions(:columns, state.column_order, new_state.column_order)
      ]

      {:ok, new_state, applied, effects}
    end
  end

  def rename(state, %Op.RenameColumn{column_id: id} = op) do
    with {:ok, column} <- Checks.column(state, id),
         {:ok, name} <- Checks.name(op.name, "column name"),
         :ok <- Checks.unique_column_name(state, name, id) do
      new_state = State.update_column(state, %{column | name: name})
      applied = %{"type" => "rename_column", "column_id" => id, "name" => name}
      effects = [{:update_column, id, %{name: name, name_key: Key.normalize(name)}}]
      {:ok, new_state, applied, effects}
    end
  end

  def change_type(state, %Op.ChangeColumnType{column_id: id, column_type: to}) do
    with {:ok, column} <- Checks.column(state, id),
         :ok <- Checks.not_label(column, "retyped"),
         {:ok, conversions} <- convert_rows(state, column, to) do
      state = State.update_column(state, %{column | column_type: to})

      new_state =
        Enum.reduce(conversions, state, fn {row, value}, acc ->
          State.update_row(acc, Checks.put_value(row, id, value))
        end)

      applied = %{
        "type" => "change_column_type",
        "column_id" => id,
        "column_type" => to,
        "cells" =>
          Enum.map(conversions, fn {row, value} -> %{"row_id" => row.id, "value" => value} end)
      }

      row_effects =
        for {row, value} <- conversions, value !== row.values[id] do
          {:update_row, row.id, %{values: Checks.put_value(row, id, value).values}}
        end

      {:ok, new_state, applied, [{:update_column, id, %{column_type: to}} | row_effects]}
    end
  end

  def move(state, %Op.MoveColumn{column_id: id, position: position}) do
    with {:ok, _column} <- Checks.column(state, id),
         {:ok, position} <- Checks.move_position(position, length(state.column_order)) do
      new_state = State.move(state, :columns, id, position)
      applied = %{"type" => "move_column", "column_id" => id, "position" => position}

      {:ok, new_state, applied,
       Checks.set_positions(:columns, state.column_order, new_state.column_order)}
    end
  end

  def delete(state, %Op.DeleteColumn{column_id: id}) do
    with {:ok, column} <- Checks.column(state, id),
         :ok <- Checks.not_label(column, "deleted") do
      new_state = State.delete_column(state, id)

      effects =
        [{:delete_column, id}, {:remove_column_values, id}] ++
          Checks.set_positions(:columns, state.column_order, new_state.column_order)

      {:ok, new_state, %{"type" => "delete_column", "column_id" => id}, effects}
    end
  end

  # Converts every non-empty value in the column, in row order. Fails on the
  # first value that can't be converted.
  defp convert_rows(state, column, to) do
    state
    |> State.rows()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case Map.fetch(row.values, column.id) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> convert_value(row, column, to, value, acc)
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp convert_value(row, column, to, value, acc) do
    case Values.convert(column.column_type, to, value) do
      {:ok, converted} ->
        {:cont, {:ok, [{row, converted} | acc]}}

      :error ->
        {:halt,
         {:error, :type_conversion_failed,
          "value #{inspect(value)} in row \"#{row.label}\" can't be converted to #{to}",
          %{row_id: row.id}}}
    end
  end
end
