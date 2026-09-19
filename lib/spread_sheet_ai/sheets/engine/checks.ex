defmodule SpreadSheetAi.Sheets.Engine.Checks do
  @moduledoc false
  # Validations and helpers shared by the engine's op modules. Every failure
  # is `{:error, code, message, meta}` with a contract §8 code.

  alias SpreadSheetAi.Sheets.{Key, State}

  @type error :: {:error, atom(), String.t(), map()}

  @doc "Trims a name; blank names fail with `code`."
  @spec name(String.t(), String.t(), atom(), map()) :: {:ok, String.t()} | error()
  def name(value, what, code \\ :invalid_op, meta \\ %{}) do
    case String.trim(value) do
      "" -> {:error, code, "#{what} can't be blank", meta}
      trimmed -> {:ok, trimmed}
    end
  end

  @doc "Fails when another column (not `except_id`) already has this name."
  @spec unique_column_name(State.t(), String.t(), Ecto.UUID.t() | nil) :: :ok | error()
  def unique_column_name(state, name, except_id \\ nil) do
    case Map.get(state.column_id_by_name_key, Key.normalize(name)) do
      nil ->
        :ok

      ^except_id ->
        :ok

      _other ->
        {:error, :duplicate_column_name, "column name \"#{name}\" is already used", %{name: name}}
    end
  end

  @spec column(State.t(), Ecto.UUID.t()) :: {:ok, State.column()} | error()
  def column(state, id) do
    case State.fetch_column(state, id) do
      {:ok, column} -> {:ok, column}
      :error -> {:error, :unknown_column, "column #{id} does not exist", %{column_id: id}}
    end
  end

  @spec row(State.t(), Ecto.UUID.t()) :: {:ok, State.row()} | error()
  def row(state, id) do
    case State.fetch_row(state, id) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_row, "row #{id} does not exist", %{row_id: id}}
    end
  end

  @doc "Fails for the label column, which can't be deleted or retyped."
  @spec not_label(State.column(), String.t()) :: :ok | error()
  def not_label(%{is_label: true} = column, action) do
    {:error, :label_column_protected, "the label column \"#{column.name}\" can't be #{action}",
     %{column_id: column.id}}
  end

  def not_label(_column, _action), do: :ok

  @doc "A client-supplied id must not already be in use."
  @spec id_free(map(), Ecto.UUID.t(), String.t()) :: :ok | error()
  def id_free(by_id, id, what) do
    if Map.has_key?(by_id, id),
      do: {:error, :invalid_op, "#{what} id #{id} is already in use", %{id: id}},
      else: :ok
  end

  @doc "An insert position: `nil` means the end; otherwise `0..length`."
  @spec insert_position(non_neg_integer() | nil, non_neg_integer()) ::
          {:ok, non_neg_integer()} | error()
  def insert_position(nil, length), do: {:ok, length}
  def insert_position(position, length), do: in_range(position, length)

  @doc "A move position: the final index, `0..length-1`."
  @spec move_position(non_neg_integer(), pos_integer()) :: {:ok, non_neg_integer()} | error()
  def move_position(position, length), do: in_range(position, length - 1)

  defp in_range(position, max) when position in 0..max//1, do: {:ok, position}

  defp in_range(position, max) do
    {:error, :invalid_position, "position #{position} is out of range 0..#{max}",
     %{position: position, max: max}}
  end

  @doc "Rejects more than `write_max_cells` rows or cells in one op."
  @spec within_cap(non_neg_integer(), %{write_max_cells: pos_integer()}, String.t()) ::
          :ok | error()
  def within_cap(count, %{write_max_cells: max}, _what) when count <= max, do: :ok

  def within_cap(count, %{write_max_cells: max}, what) do
    {:error, :too_many_cells,
     "at most #{max} #{what} per operation (got #{count}); split the change into several operations",
     %{max: max}}
  end

  @doc """
  The `{:set_positions, kind, [{id, position}]}` effect for ids whose index
  changed between `old_order` and `new_order`. Ids only in one of them
  (inserted or deleted) are left out. Returns `[]` when nothing moved.
  """
  @spec set_positions(:columns | :rows, [Ecto.UUID.t()], [Ecto.UUID.t()]) :: [tuple()]
  def set_positions(kind, old_order, new_order) do
    old_index = old_order |> Enum.with_index() |> Map.new()

    moved =
      new_order
      |> Enum.with_index()
      |> Enum.filter(fn {id, index} -> Map.has_key?(old_index, id) and old_index[id] != index end)

    if moved == [], do: [], else: [{:set_positions, kind, moved}]
  end

  @doc "Sets a value in a row's `values`; `nil` removes the key."
  @spec put_value(State.row(), Ecto.UUID.t(), term()) :: State.row()
  def put_value(row, column_id, nil), do: %{row | values: Map.delete(row.values, column_id)}
  def put_value(row, column_id, value), do: %{row | values: Map.put(row.values, column_id, value)}
end
