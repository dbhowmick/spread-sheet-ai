defmodule SpreadSheetAi.Sheets.Named do
  @moduledoc """
  Turns a name-based op, as the AI tools write it, into an id-based
  `SpreadSheetAi.Sheets.Op` (backend-plan §8.2). Rows are named by label
  and columns by name, both trimmed and case-insensitive.

  It runs inside the sheet server, against the state the op is then applied
  to, so a name always means the row or column it names at that version.
  It never raises: anything malformed is an `invalid_op` error.

  Named ops (string keys):

    * `rename_sheet` — `name`
    * `add_column` — `name`, `column_type`, `position?`
    * `rename_column` — `column`, `name`
    * `change_column_type` — `column`, `column_type`
    * `move_column` — `column`, `position`
    * `delete_column` — `column`
    * `add_rows` — `rows: [%{"label", "values" => %{column_name => value}}]`, `position?`
    * `delete_rows` — `labels`
    * `move_row` — `label`, `position`
    * `set_cells` — `cells: [%{"row", "column", "value"}]`

  The id-based op is built as contract §6 JSON and checked by
  `SpreadSheetAi.Sheets.Op.parse/1`, so shape rules live in one place.
  """

  alias SpreadSheetAi.Sheets.{Op, Reads, State}

  @type error :: {:error, atom(), String.t(), map()}

  @doc "Resolves a named op against `state`."
  @spec resolve(State.t(), term()) :: {:ok, Op.t()} | error()
  def resolve(%State{} = state, %{"type" => type} = op) when is_binary(type),
    do: resolve_type(type, op, state)

  def resolve(%State{}, _op), do: invalid(~s(op must be an object with a string "type"))

  defp resolve_type("rename_sheet", op, _state),
    do: Op.parse(Map.take(op, ["type", "name"]))

  defp resolve_type("add_column", op, _state),
    do: Op.parse(Map.take(op, ["type", "name", "column_type", "position"]))

  defp resolve_type("rename_column", op, state) do
    with {:ok, column} <- column(state, op["column"], "column"),
         do: parse(op, %{"column_id" => column.id, "name" => op["name"]})
  end

  defp resolve_type("change_column_type", op, state) do
    with {:ok, column} <- column(state, op["column"], "column"),
         do: parse(op, %{"column_id" => column.id, "column_type" => op["column_type"]})
  end

  defp resolve_type("move_column", op, state) do
    with {:ok, column} <- column(state, op["column"], "column"),
         do: parse(op, %{"column_id" => column.id, "position" => op["position"]})
  end

  defp resolve_type("delete_column", op, state) do
    with {:ok, column} <- column(state, op["column"], "column"),
         do: parse(op, %{"column_id" => column.id})
  end

  defp resolve_type("add_rows", op, state) do
    with {:ok, rows} <- list(op, "rows"),
         {:ok, rows} <- map_all(rows, &new_row(state, &1)),
         do: parse(op, %{"rows" => rows, "position" => op["position"]})
  end

  defp resolve_type("delete_rows", op, state) do
    with {:ok, labels} <- list(op, "labels"),
         {:ok, rows} <- map_all(labels, &row(state, &1, "labels")),
         :ok <- no_duplicates(rows, & &1.id, &~s(row "#{&1.label}" is listed twice)) do
      parse(op, %{"row_ids" => Enum.map(rows, & &1.id)})
    end
  end

  defp resolve_type("move_row", op, state) do
    with {:ok, row} <- row(state, op["label"], "label"),
         do: parse(op, %{"row_id" => row.id, "position" => op["position"]})
  end

  defp resolve_type("set_cells", op, state) do
    with {:ok, cells} <- list(op, "cells"),
         {:ok, cells} <- map_all(cells, &cell(state, &1)),
         :ok <-
           no_duplicates(
             cells,
             &{&1.row.id, &1.column.id},
             &~s(cell "#{&1.row.label}" / "#{&1.column.name}" is set twice)
           ) do
      cells =
        Enum.map(
          cells,
          &%{"row_id" => &1.row.id, "column_id" => &1.column.id, "value" => &1.value}
        )

      parse(op, %{"cells" => cells})
    end
  end

  defp resolve_type(type, _op, _state), do: invalid("unknown op type #{inspect(type)}", "type")

  # A new row's label goes into the label column's cell; values are keyed by
  # column name.
  defp new_row(state, %{} = row) do
    with {:ok, values} <- values(row),
         {:ok, cells} <- map_all(Map.to_list(values), &value_cell(state, &1)),
         :ok <-
           no_duplicates(cells, &elem(&1, 0), fn {id, _value} ->
             ~s(column "#{state.columns_by_id[id].name}" is given twice in one row)
           end) do
      {:ok, %{"cells" => Map.new([{state.label_column_id, Map.get(row, "label")} | cells])}}
    end
  end

  defp new_row(_state, _row), do: invalid("each row must be an object", "rows")

  defp values(row) do
    case Map.get(row, "values", %{}) do
      %{} = values -> {:ok, values}
      nil -> {:ok, %{}}
      _ -> invalid(~s("values" must be an object keyed by column name), "rows")
    end
  end

  defp value_cell(state, {name, value}) do
    case column(state, name, "values") do
      {:ok, %{is_label: true}} ->
        invalid(~s[put the row's label in "label", not in "values"], "rows")

      {:ok, column} ->
        {:ok, {column.id, value}}

      error ->
        error
    end
  end

  defp cell(state, %{"value" => value} = cell) do
    with {:ok, row} <- row(state, cell["row"], "cells"),
         {:ok, column} <- column(state, cell["column"], "cells") do
      {:ok, %{row: row, column: column, value: value}}
    end
  end

  defp cell(_state, %{}),
    do: invalid(~s[each cell needs "row", "column" and "value" (null clears it)], "cells")

  defp cell(_state, _cell), do: invalid("each cell must be an object", "cells")

  # ----- Lookups -----

  defp column(state, name, _key) when is_binary(name), do: Reads.fetch_column(state, name)
  defp column(_state, _name, key), do: invalid("column names must be strings", key)

  defp row(state, label, _key) when is_binary(label), do: Reads.fetch_row(state, label)
  defp row(_state, _label, key), do: invalid("row labels must be strings", key)

  # ----- Helpers -----

  defp parse(%{"type" => type}, fields),
    do: fields |> Map.reject(fn {_k, v} -> is_nil(v) end) |> Map.put("type", type) |> Op.parse()

  defp list(op, key) do
    case Map.get(op, key) do
      [_ | _] = list -> {:ok, list}
      [] -> invalid(~s("#{key}" must not be empty), key)
      _ -> invalid(~s("#{key}" must be a list), key)
    end
  end

  defp no_duplicates(items, key_fun, message_fun) do
    items
    |> Enum.reduce_while(MapSet.new(), fn item, seen ->
      key = key_fun.(item)

      if MapSet.member?(seen, key),
        do: {:halt, {:duplicate, item}},
        else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      {:duplicate, item} -> invalid(message_fun.(item))
      _seen -> :ok
    end
  end

  # Maps `fun` over `list`, stopping at the first error.
  defp map_all(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp invalid(message, field \\ nil),
    do: {:error, :invalid_op, message, if(field, do: %{field: field}, else: %{})}
end
