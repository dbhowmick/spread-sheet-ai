defmodule SpreadSheetAi.Sheets.Engine.Rows do
  @moduledoc false
  # Row and cell ops: add_rows, delete_rows, move_row, set_cells. Also
  # builds validated rows for `Engine.create/3`.

  alias SpreadSheetAi.Sheets.Engine.Checks
  alias SpreadSheetAi.Sheets.{Key, Op, State, Values}

  def add(state, %Op.AddRows{rows: rows, position: position}, limits) do
    with :ok <- Checks.within_cap(length(rows), limits, "rows"),
         {:ok, position} <- Checks.insert_position(position, length(state.row_order)),
         {:ok, new_rows} <- build_rows(state, rows) do
      new_state = State.insert_rows(state, new_rows, position)

      applied = %{
        "type" => "add_rows",
        "position" => position,
        "rows" => Enum.map(new_rows, &%{"id" => &1.id, "cells" => State.row_cells(new_state, &1)})
      }

      effects = [
        {:insert_rows, row_attrs(new_rows, position)}
        | Checks.set_positions(:rows, state.row_order, new_state.row_order)
      ]

      {:ok, new_state, applied, effects}
    end
  end

  def delete(state, %Op.DeleteRows{row_ids: ids}) do
    with :ok <- all_exist(state, ids) do
      new_state = State.delete_rows(state, ids)

      effects = [
        {:delete_rows, ids} | Checks.set_positions(:rows, state.row_order, new_state.row_order)
      ]

      {:ok, new_state, %{"type" => "delete_rows", "row_ids" => ids}, effects}
    end
  end

  def move(state, %Op.MoveRow{row_id: id, position: position}) do
    with {:ok, _row} <- Checks.row(state, id),
         {:ok, position} <- Checks.move_position(position, length(state.row_order)) do
      new_state = State.move(state, :rows, id, position)
      applied = %{"type" => "move_row", "row_id" => id, "position" => position}
      {:ok, new_state, applied, Checks.set_positions(:rows, state.row_order, new_state.row_order)}
    end
  end

  def set_cells(state, %Op.SetCells{cells: cells}, limits) do
    with :ok <- Checks.within_cap(length(cells), limits, "cells"),
         {:ok, touched, applied_cells} <- apply_cells(state, cells),
         :ok <- final_labels_unique(state, touched) do
      touched_rows = Enum.map(touched.order, &touched.rows[&1])
      new_state = Enum.reduce(touched_rows, state, &State.update_row(&2, &1))
      effects = Enum.flat_map(touched_rows, &row_update_effect(state.rows_by_id[&1.id], &1))
      {:ok, new_state, %{"type" => "set_cells", "cells" => applied_cells}, effects}
    end
  end

  @doc """
  Validates new rows (`%{id, cells}` keyed by column id, label included)
  against `state` and each other, filling in missing ids. Returns rows as
  `%{id, label, values}`.
  """
  def build_rows(state, rows) do
    rows
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn row, {:ok, acc, seen} ->
      case build_row(state, row, seen) do
        {:ok, built} ->
          {:cont, {:ok, [built | acc], MapSet.put(seen, Key.normalize(built.label))}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, _seen} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc "Row attributes for an `:insert_rows` effect, positioned from `first`."
  def row_attrs(rows, first) do
    rows
    |> Enum.with_index(first)
    |> Enum.map(fn {row, position} ->
      Map.merge(row, %{label_key: Key.normalize(row.label), position: position})
    end)
  end

  defp build_row(state, %{id: id, cells: cells}, seen) do
    id = id || Ecto.UUID.generate()
    label_column_id = state.label_column_id

    with :ok <- Checks.id_free(state.rows_by_id, id, "row"),
         {:ok, label} <- label(state, id, Map.get(cells, label_column_id)),
         :ok <- label_free(state, label, seen),
         {:ok, values} <- cast_values(state, id, label, Map.delete(cells, label_column_id)) do
      {:ok, %{id: id, label: label, values: values}}
    end
  end

  defp cast_values(state, row_id, label, cells) do
    cells
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {column_id, value}, {:ok, values} ->
      with {:ok, column} <- Checks.column(state, column_id),
           {:ok, stored} <- cast_cell(column, row_id, label, value) do
        {:cont, {:ok, if(is_nil(stored), do: values, else: Map.put(values, column_id, stored))}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # ----- set_cells -----

  # Applies each cell to its (possibly already touched) row, in op order.
  # `touched` keeps first-touch order so effects are deterministic.
  defp apply_cells(state, cells) do
    cells
    |> Enum.reduce_while({:ok, %{order: [], rows: %{}}, []}, fn cell, {:ok, touched, applied} ->
      case apply_cell(state, touched, cell) do
        {:ok, row, value} ->
          touched = %{
            order:
              if(Map.has_key?(touched.rows, row.id),
                do: touched.order,
                else: [row.id | touched.order]
              ),
            rows: Map.put(touched.rows, row.id, row)
          }

          applied_cell = %{"row_id" => row.id, "column_id" => cell.column_id, "value" => value}
          {:cont, {:ok, touched, [applied_cell | applied]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, touched, applied} ->
        {:ok, %{touched | order: Enum.reverse(touched.order)}, Enum.reverse(applied)}

      error ->
        error
    end
  end

  defp apply_cell(state, touched, %{row_id: row_id, column_id: column_id, value: value}) do
    with {:ok, row} <- touched_or_existing_row(state, touched, row_id),
         {:ok, column} <- Checks.column(state, column_id) do
      set_cell(state, row, column, value)
    end
  end

  defp touched_or_existing_row(state, touched, row_id) do
    case Map.fetch(touched.rows, row_id) do
      {:ok, row} -> {:ok, row}
      :error -> Checks.row(state, row_id)
    end
  end

  # Setting the label cell renames the row.
  defp set_cell(state, row, %{is_label: true}, value) do
    with {:ok, label} <- label(state, row.id, value), do: {:ok, %{row | label: label}, label}
  end

  defp set_cell(_state, row, column, value) do
    with {:ok, stored} <- cast_cell(column, row.id, row.label, value),
         do: {:ok, Checks.put_value(row, column.id, stored), stored}
  end

  # Labels are checked on their final values, so two rows can swap labels
  # in one op.
  defp final_labels_unique(state, touched) do
    renamed =
      touched.order
      |> Enum.map(&touched.rows[&1])
      |> Enum.filter(&(&1.label != state.rows_by_id[&1.id].label))

    renamed_ids = MapSet.new(renamed, & &1.id)

    others =
      Map.reject(state.row_id_by_label_key, fn {_key, id} -> MapSet.member?(renamed_ids, id) end)

    renamed
    |> Enum.reduce_while(MapSet.new(), fn row, seen ->
      key = Key.normalize(row.label)

      if Map.has_key?(others, key) or MapSet.member?(seen, key),
        do: {:halt, duplicate_label(row.label)},
        else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp row_update_effect(original, row) do
    fields = if row.values != original.values, do: %{values: row.values}, else: %{}

    fields =
      if row.label != original.label,
        do: Map.merge(fields, %{label: row.label, label_key: Key.normalize(row.label)}),
        else: fields

    if fields == %{}, do: [], else: [{:update_row, row.id, fields}]
  end

  # ----- Shared -----

  # A label is a required, trimmed text value.
  defp label(state, row_id, value) do
    case Values.cast("text", value) do
      {:ok, nil} ->
        label_required(row_id)

      {:ok, text} ->
        case String.trim(text) do
          "" -> label_required(row_id)
          label -> {:ok, label}
        end

      {:error, :invalid_value} ->
        {:error, :invalid_value, "row label must be text, got #{inspect(value)}",
         %{row_id: row_id, column_id: state.label_column_id}}
    end
  end

  defp label_free(state, label, seen) do
    key = Key.normalize(label)

    if Map.has_key?(state.row_id_by_label_key, key) or MapSet.member?(seen, key),
      do: duplicate_label(label),
      else: :ok
  end

  defp cast_cell(column, row_id, label, value) do
    case Values.cast(column.column_type, value) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, :invalid_value} ->
        {:error, :invalid_value,
         "#{inspect(value)} is not a valid #{column.column_type} for column \"#{column.name}\" in row \"#{label}\"",
         %{row_id: row_id, column_id: column.id}}
    end
  end

  defp all_exist(state, ids) do
    case Enum.find(ids, &(not Map.has_key?(state.rows_by_id, &1))) do
      nil -> :ok
      id -> Checks.row(state, id)
    end
  end

  defp label_required(row_id),
    do: {:error, :label_required, "row label is required", %{row_id: row_id}}

  defp duplicate_label(label),
    do: {:error, :duplicate_label, "label \"#{label}\" is already used", %{label: label}}
end
