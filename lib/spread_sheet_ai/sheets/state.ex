defmodule SpreadSheetAi.Sheets.State do
  @moduledoc """
  A sheet held in memory: its columns and rows in display order, plus lookup
  indexes by id and by normalized name / label.

  Order lives in `column_order` / `row_order` (lists of ids); the entities
  live only in `columns_by_id` / `rows_by_id`. A row's `values` excludes the
  label, as in `sheet_rows`; `row_cells/2` adds it back.

  `owner`, `inserted_at` and `updated_at` are sheet metadata for snapshots.
  The engine never reads or changes them; `load/3` and the sheet server
  fill them in.

  The functions that change a State (`insert_*`, `update_*`, `delete_*`,
  `move`) keep every index in step; the engine only goes through them.
  """

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.Sheets.{Column, Key, Row, Sheet}

  @type column :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          column_type: String.t(),
          is_label: boolean()
        }
  @type row :: %{id: Ecto.UUID.t(), label: String.t(), values: %{Ecto.UUID.t() => term()}}
  @type owner :: %{id: Ecto.UUID.t(), display_name: String.t() | nil}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          owner_id: Ecto.UUID.t() | nil,
          owner: owner() | nil,
          version: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          label_column_id: Ecto.UUID.t() | nil,
          column_order: [Ecto.UUID.t()],
          columns_by_id: %{Ecto.UUID.t() => column()},
          column_id_by_name_key: %{String.t() => Ecto.UUID.t()},
          row_order: [Ecto.UUID.t()],
          rows_by_id: %{Ecto.UUID.t() => row()},
          row_id_by_label_key: %{String.t() => Ecto.UUID.t()}
        }

  defstruct id: nil,
            name: nil,
            owner_id: nil,
            owner: nil,
            version: 0,
            inserted_at: nil,
            updated_at: nil,
            label_column_id: nil,
            column_order: [],
            columns_by_id: %{},
            column_id_by_name_key: %{},
            row_order: [],
            rows_by_id: %{},
            row_id_by_label_key: %{}

  @doc "An empty State for a sheet."
  @spec new(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), non_neg_integer()) :: t()
  def new(id, name, owner_id, version \\ 0),
    do: %__MODULE__{id: id, name: name, owner_id: owner_id, version: version}

  @doc """
  Builds a State from a sheet and its column and row records (in any order).
  The owner is taken from `sheet.owner` when it is preloaded.
  """
  @spec load(Sheet.t(), [Column.t()], [Row.t()]) :: t()
  def load(%Sheet{} = sheet, columns, rows) do
    columns =
      columns
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&Map.take(&1, [:id, :name, :column_type, :is_label]))

    rows =
      rows
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&Map.take(&1, [:id, :label, :values]))

    state = new(sheet.id, sheet.name, sheet.owner_id, sheet.version)

    %{
      state
      | owner: owner(sheet.owner),
        inserted_at: sheet.inserted_at,
        updated_at: sheet.updated_at
    }
    |> insert_columns(columns, 0)
    |> insert_rows(rows, 0)
  end

  @doc "The `owner` of a State, from a user."
  @spec owner(User.t() | term()) :: owner() | nil
  def owner(%User{} = user), do: %{id: user.id, display_name: User.display_name(user)}
  def owner(_not_loaded), do: nil

  # ----- Reads -----

  @doc "Columns in display order."
  @spec columns(t()) :: [column()]
  def columns(%__MODULE__{} = state), do: Enum.map(state.column_order, &state.columns_by_id[&1])

  @doc "Rows in display order."
  @spec rows(t()) :: [row()]
  def rows(%__MODULE__{} = state), do: Enum.map(state.row_order, &state.rows_by_id[&1])

  @spec fetch_column(t(), Ecto.UUID.t()) :: {:ok, column()} | :error
  def fetch_column(%__MODULE__{} = state, id), do: Map.fetch(state.columns_by_id, id)

  @spec fetch_row(t(), Ecto.UUID.t()) :: {:ok, row()} | :error
  def fetch_row(%__MODULE__{} = state, id), do: Map.fetch(state.rows_by_id, id)

  @doc "Finds a column by name, trimmed and case-insensitive."
  @spec fetch_column_by_name(t(), String.t()) :: {:ok, column()} | :error
  def fetch_column_by_name(%__MODULE__{} = state, name) when is_binary(name) do
    with {:ok, id} <- Map.fetch(state.column_id_by_name_key, Key.normalize(name)),
         do: fetch_column(state, id)
  end

  @doc "Finds a row by label, trimmed and case-insensitive."
  @spec fetch_row_by_label(t(), String.t()) :: {:ok, row()} | :error
  def fetch_row_by_label(%__MODULE__{} = state, label) when is_binary(label) do
    with {:ok, id} <- Map.fetch(state.row_id_by_label_key, Key.normalize(label)),
         do: fetch_row(state, id)
  end

  @doc "A row's cells keyed by column id, including the label."
  @spec row_cells(t(), row()) :: %{Ecto.UUID.t() => term()}
  def row_cells(%__MODULE__{} = state, row),
    do: Map.put(row.values, state.label_column_id, row.label)

  # ----- Changes (indexes kept in step) -----

  @doc "Inserts `columns` so the first one lands at index `at`."
  @spec insert_columns(t(), [column()], non_neg_integer()) :: t()
  def insert_columns(%__MODULE__{} = state, columns, at) do
    state =
      Enum.reduce(columns, state, fn column, acc ->
        acc
        |> put_column(column)
        |> maybe_set_label_column(column)
      end)

    %{state | column_order: insert_ids(state.column_order, Enum.map(columns, & &1.id), at)}
  end

  @doc "Inserts `rows` so the first one lands at index `at`."
  @spec insert_rows(t(), [row()], non_neg_integer()) :: t()
  def insert_rows(%__MODULE__{} = state, rows, at) do
    state = Enum.reduce(rows, state, &put_row(&2, &1))
    %{state | row_order: insert_ids(state.row_order, Enum.map(rows, & &1.id), at)}
  end

  @doc "Replaces a column (same id), re-indexing its name."
  @spec update_column(t(), column()) :: t()
  def update_column(%__MODULE__{} = state, %{id: id} = column) do
    old = Map.fetch!(state.columns_by_id, id)

    %{
      state
      | columns_by_id: Map.put(state.columns_by_id, id, column),
        column_id_by_name_key: reindex(state.column_id_by_name_key, old.name, column.name, id)
    }
  end

  @doc "Replaces a row (same id), re-indexing its label."
  @spec update_row(t(), row()) :: t()
  def update_row(%__MODULE__{} = state, %{id: id} = row) do
    old = Map.fetch!(state.rows_by_id, id)

    %{
      state
      | rows_by_id: Map.put(state.rows_by_id, id, row),
        row_id_by_label_key: reindex(state.row_id_by_label_key, old.label, row.label, id)
    }
  end

  @doc "Removes a column and its values from every row."
  @spec delete_column(t(), Ecto.UUID.t()) :: t()
  def delete_column(%__MODULE__{} = state, id) do
    column = Map.fetch!(state.columns_by_id, id)

    rows_by_id =
      Map.new(state.rows_by_id, fn {row_id, row} ->
        {row_id, %{row | values: Map.delete(row.values, id)}}
      end)

    %{
      state
      | column_order: List.delete(state.column_order, id),
        columns_by_id: Map.delete(state.columns_by_id, id),
        column_id_by_name_key:
          Map.delete(state.column_id_by_name_key, Key.normalize(column.name)),
        rows_by_id: rows_by_id
    }
  end

  @doc "Removes rows by id."
  @spec delete_rows(t(), [Ecto.UUID.t()]) :: t()
  def delete_rows(%__MODULE__{} = state, ids) do
    deleted = MapSet.new(ids)

    %{
      state
      | row_order: Enum.reject(state.row_order, &MapSet.member?(deleted, &1)),
        rows_by_id: Map.drop(state.rows_by_id, ids),
        row_id_by_label_key:
          Map.reject(state.row_id_by_label_key, fn {_key, id} -> MapSet.member?(deleted, id) end)
    }
  end

  @doc "Moves a column or row so it ends up at index `to`."
  @spec move(t(), :columns | :rows, Ecto.UUID.t(), non_neg_integer()) :: t()
  def move(%__MODULE__{} = state, :columns, id, to),
    do: %{state | column_order: move_id(state.column_order, id, to)}

  def move(%__MODULE__{} = state, :rows, id, to),
    do: %{state | row_order: move_id(state.row_order, id, to)}

  # ----- Helpers -----

  defp put_column(state, column) do
    %{
      state
      | columns_by_id: Map.put(state.columns_by_id, column.id, column),
        column_id_by_name_key:
          Map.put(state.column_id_by_name_key, Key.normalize(column.name), column.id)
    }
  end

  defp maybe_set_label_column(state, %{is_label: true, id: id}),
    do: %{state | label_column_id: id}

  defp maybe_set_label_column(state, _column), do: state

  defp put_row(state, row) do
    %{
      state
      | rows_by_id: Map.put(state.rows_by_id, row.id, row),
        row_id_by_label_key: Map.put(state.row_id_by_label_key, Key.normalize(row.label), row.id)
    }
  end

  # Drops the old key only while it still points at `id`: when two labels are
  # swapped, the other row may already own it.
  defp reindex(index, old_name, new_name, id) do
    old_key = Key.normalize(old_name)
    index = if Map.get(index, old_key) == id, do: Map.delete(index, old_key), else: index
    Map.put(index, Key.normalize(new_name), id)
  end

  defp insert_ids(order, ids, at) do
    {before, rest} = Enum.split(order, at)
    before ++ ids ++ rest
  end

  defp move_id(order, id, to), do: order |> List.delete(id) |> List.insert_at(to, id)
end
