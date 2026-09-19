defmodule SpreadSheetAi.Sheets.Op do
  @moduledoc """
  Parses contract §6 `Op` JSON (string keys) into typed structs.

  Parsing checks shape only: known `type`, required fields present with the
  right JSON types, ids that are UUIDs, known column types, non-empty lists
  and no duplicates inside one op. Whether ids exist, names are unique or
  values match their columns is the engine's job (`SpreadSheetAi.Sheets.Engine`).

  Op types go through an explicit whitelist; no atoms are built from input.
  Every error is `{:error, code, message, meta}` with a contract §8 code.
  """

  alias SpreadSheetAi.Sheets.Column

  defmodule RenameSheet do
    @moduledoc false
    @enforce_keys [:name]
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule AddColumn do
    @moduledoc false
    @enforce_keys [:name, :column_type]
    defstruct [:id, :name, :column_type, :position]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t() | nil,
            name: String.t(),
            column_type: String.t(),
            position: non_neg_integer() | nil
          }
  end

  defmodule RenameColumn do
    @moduledoc false
    @enforce_keys [:column_id, :name]
    defstruct [:column_id, :name]
    @type t :: %__MODULE__{column_id: Ecto.UUID.t(), name: String.t()}
  end

  defmodule ChangeColumnType do
    @moduledoc false
    @enforce_keys [:column_id, :column_type]
    defstruct [:column_id, :column_type]
    @type t :: %__MODULE__{column_id: Ecto.UUID.t(), column_type: String.t()}
  end

  defmodule MoveColumn do
    @moduledoc false
    @enforce_keys [:column_id, :position]
    defstruct [:column_id, :position]
    @type t :: %__MODULE__{column_id: Ecto.UUID.t(), position: non_neg_integer()}
  end

  defmodule DeleteColumn do
    @moduledoc false
    @enforce_keys [:column_id]
    defstruct [:column_id]
    @type t :: %__MODULE__{column_id: Ecto.UUID.t()}
  end

  defmodule AddRows do
    @moduledoc false
    @enforce_keys [:rows]
    defstruct [:rows, :position]

    @type new_row :: %{id: Ecto.UUID.t() | nil, cells: %{Ecto.UUID.t() => term()}}
    @type t :: %__MODULE__{rows: [new_row()], position: non_neg_integer() | nil}
  end

  defmodule DeleteRows do
    @moduledoc false
    @enforce_keys [:row_ids]
    defstruct [:row_ids]
    @type t :: %__MODULE__{row_ids: [Ecto.UUID.t()]}
  end

  defmodule MoveRow do
    @moduledoc false
    @enforce_keys [:row_id, :position]
    defstruct [:row_id, :position]
    @type t :: %__MODULE__{row_id: Ecto.UUID.t(), position: non_neg_integer()}
  end

  defmodule SetCells do
    @moduledoc false
    @enforce_keys [:cells]
    defstruct [:cells]

    @type cell :: %{row_id: Ecto.UUID.t(), column_id: Ecto.UUID.t(), value: term()}
    @type t :: %__MODULE__{cells: [cell()]}
  end

  defmodule CreateSheet do
    @moduledoc false
    @enforce_keys [:name]
    defstruct name: nil, label_column_name: "Line item", columns: [], rows: []

    @type t :: %__MODULE__{
            name: String.t(),
            label_column_name: String.t(),
            columns: [%{name: String.t(), column_type: String.t()}],
            rows: [%{label: term(), values: %{String.t() => term()}}]
          }
  end

  @type t ::
          RenameSheet.t()
          | AddColumn.t()
          | RenameColumn.t()
          | ChangeColumnType.t()
          | MoveColumn.t()
          | DeleteColumn.t()
          | AddRows.t()
          | DeleteRows.t()
          | MoveRow.t()
          | SetCells.t()

  @type error :: {:error, atom(), String.t(), map()}

  @doc "Parses an `Op` map (contract §6) into its struct."
  @spec parse(term()) :: {:ok, t()} | error()
  def parse(%{"type" => type} = op) when is_binary(type), do: parse_type(type, op)
  def parse(%{} = _op), do: invalid("op must have a string \"type\"", "type")
  def parse(_op), do: invalid("op must be an object")

  defp parse_type("rename_sheet", op) do
    with {:ok, name} <- string(op, "name"), do: {:ok, %RenameSheet{name: name}}
  end

  defp parse_type("add_column", op) do
    with {:ok, id} <- optional_uuid(op, "id"),
         {:ok, name} <- string(op, "name"),
         {:ok, column_type} <- column_type(op),
         {:ok, position} <- optional_position(op) do
      {:ok, %AddColumn{id: id, name: name, column_type: column_type, position: position}}
    end
  end

  defp parse_type("rename_column", op) do
    with {:ok, column_id} <- uuid(op, "column_id"),
         {:ok, name} <- string(op, "name") do
      {:ok, %RenameColumn{column_id: column_id, name: name}}
    end
  end

  defp parse_type("change_column_type", op) do
    with {:ok, column_id} <- uuid(op, "column_id"),
         {:ok, column_type} <- column_type(op) do
      {:ok, %ChangeColumnType{column_id: column_id, column_type: column_type}}
    end
  end

  defp parse_type("move_column", op) do
    with {:ok, column_id} <- uuid(op, "column_id"),
         {:ok, position} <- position(op) do
      {:ok, %MoveColumn{column_id: column_id, position: position}}
    end
  end

  defp parse_type("delete_column", op) do
    with {:ok, column_id} <- uuid(op, "column_id"), do: {:ok, %DeleteColumn{column_id: column_id}}
  end

  defp parse_type("add_rows", op) do
    with {:ok, rows} <- non_empty_list(op, "rows"),
         {:ok, rows} <- map_all(rows, &new_row/1),
         :ok <-
           no_duplicates(rows |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1), "rows", "row id"),
         {:ok, position} <- optional_position(op) do
      {:ok, %AddRows{rows: rows, position: position}}
    end
  end

  defp parse_type("delete_rows", op) do
    with {:ok, ids} <- non_empty_list(op, "row_ids"),
         {:ok, ids} <- map_all(ids, &cast_uuid(&1, "row_ids")),
         :ok <- no_duplicates(ids, "row_ids", "row id") do
      {:ok, %DeleteRows{row_ids: ids}}
    end
  end

  defp parse_type("move_row", op) do
    with {:ok, row_id} <- uuid(op, "row_id"),
         {:ok, position} <- position(op) do
      {:ok, %MoveRow{row_id: row_id, position: position}}
    end
  end

  defp parse_type("set_cells", op) do
    with {:ok, cells} <- non_empty_list(op, "cells"),
         {:ok, cells} <- map_all(cells, &cell/1),
         :ok <- no_duplicates(Enum.map(cells, &{&1.row_id, &1.column_id}), "cells", "cell") do
      {:ok, %SetCells{cells: cells}}
    end
  end

  defp parse_type(type, _op), do: invalid("unknown op type #{inspect(type)}", "type")

  defp new_row(%{} = row) do
    with {:ok, id} <- optional_uuid(row, "id"),
         {:ok, cells} <- cells_map(row) do
      {:ok, %{id: id, cells: cells}}
    end
  end

  defp new_row(_row), do: invalid("each row must be an object", "rows")

  defp cells_map(row) do
    case Map.get(row, "cells", %{}) do
      %{} = cells ->
        with {:ok, pairs} <- map_all(Map.to_list(cells), &cell_entry/1), do: {:ok, Map.new(pairs)}

      _ ->
        invalid("\"cells\" must be an object keyed by column id", "cells")
    end
  end

  defp cell_entry({column_id, value}) do
    with {:ok, id} <- cast_uuid(column_id, "cells"), do: {:ok, {id, value}}
  end

  defp cell(%{"value" => value} = cell) do
    with {:ok, row_id} <- uuid(cell, "row_id"),
         {:ok, column_id} <- uuid(cell, "column_id") do
      {:ok, %{row_id: row_id, column_id: column_id, value: value}}
    end
  end

  defp cell(%{}), do: invalid("each cell must have a \"value\" (null clears it)", "cells")
  defp cell(_cell), do: invalid("each cell must be an object", "cells")

  @doc """
  Parses the params for creating a sheet (REST `POST /api/sheets` and the
  AI `create_sheet` tool): `name`, `label_column_name?` (default
  `"Line item"`), `columns?: [{name, column_type}]` and
  `rows?: [{label, values: {column_name => value}}]`. Errors use
  `validation_failed` with a `field`.
  """
  @spec parse_create(term()) :: {:ok, CreateSheet.t()} | error()
  def parse_create(%{} = params) do
    with {:ok, name} <- create_string(params, "name", nil),
         {:ok, label_column_name} <- create_string(params, "label_column_name", "Line item"),
         {:ok, columns} <- create_list(params, "columns", &create_column/1),
         {:ok, rows} <- create_list(params, "rows", &create_row/1) do
      {:ok,
       %CreateSheet{
         name: name,
         label_column_name: label_column_name,
         columns: columns,
         rows: rows
       }}
    end
  end

  def parse_create(_params), do: validation_failed("must be an object", "params")

  defp create_string(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      nil when is_binary(default) -> {:ok, default}
      nil -> validation_failed("can't be blank", key)
      _ -> validation_failed("must be a string", key)
    end
  end

  defp create_list(params, key, fun) do
    case Map.get(params, key) do
      nil -> {:ok, []}
      list when is_list(list) -> map_all(list, fun)
      _ -> validation_failed("must be a list", key)
    end
  end

  defp create_column(%{"name" => name, "column_type" => type}) when is_binary(name) do
    if type in Column.types(),
      do: {:ok, %{name: name, column_type: type}},
      else:
        validation_failed(
          "column_type must be one of #{Enum.join(Column.types(), ", ")}",
          "columns"
        )
  end

  defp create_column(_column),
    do: validation_failed(~s(each column needs a string "name" and a "column_type"), "columns")

  defp create_row(%{} = row) do
    label = Map.get(row, "label")
    values = Map.get(row, "values", %{})

    cond do
      not (is_nil(label) or is_binary(label)) ->
        validation_failed("label must be a string", "rows")

      not is_map(values) ->
        validation_failed("values must be an object keyed by column name", "rows")

      true ->
        {:ok, %{label: label, values: values}}
    end
  end

  defp create_row(_row), do: validation_failed("each row must be an object", "rows")

  # ----- Field helpers -----

  defp string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> invalid("\"#{key}\" must be a string", key)
    end
  end

  defp uuid(map, key), do: cast_uuid(Map.get(map, key), key)

  defp optional_uuid(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> cast_uuid(value, key)
    end
  end

  defp cast_uuid(value, key) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid("\"#{key}\" must contain UUIDs, got #{inspect(value)}", key)
    end
  end

  defp column_type(op) do
    type = Map.get(op, "column_type")

    if type in Column.types(),
      do: {:ok, type},
      else:
        invalid(
          "\"column_type\" must be one of #{Enum.join(Column.types(), ", ")}",
          "column_type"
        )
  end

  defp position(op) do
    case Map.get(op, "position") do
      nil -> invalid("\"position\" is required", "position")
      _ -> optional_position(op)
    end
  end

  defp optional_position(op) do
    case Map.get(op, "position") do
      nil ->
        {:ok, nil}

      position when is_integer(position) and position >= 0 ->
        {:ok, position}

      position when is_integer(position) ->
        {:error, :invalid_position, "position #{position} is out of range", %{position: position}}

      _ ->
        invalid("\"position\" must be an integer", "position")
    end
  end

  defp non_empty_list(map, key) do
    case Map.get(map, key) do
      [_ | _] = list -> {:ok, list}
      [] -> invalid("\"#{key}\" must not be empty", key)
      _ -> invalid("\"#{key}\" must be a list", key)
    end
  end

  defp no_duplicates(items, key, what) do
    items
    |> Enum.reduce_while(MapSet.new(), fn item, seen ->
      if MapSet.member?(seen, item),
        do: {:halt, {:duplicate, item}},
        else: {:cont, MapSet.put(seen, item)}
    end)
    |> case do
      {:duplicate, item} -> invalid("duplicate #{what} #{inspect(item)} in one op", key)
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

  defp validation_failed(message, field),
    do: {:error, :validation_failed, message, %{field: field}}
end
