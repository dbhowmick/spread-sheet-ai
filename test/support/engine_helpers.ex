defmodule SpreadSheetAi.EngineHelpers do
  @moduledoc """
  Helpers for pure engine tests. States are always built through
  `Engine.create/3` so tests never hand-build indexes, and every successful
  apply is checked with `assert_consistent/1`.
  """

  import ExUnit.Assertions

  alias SpreadSheetAi.Sheets.{Engine, Key, Op, State}

  @limits %{write_max_cells: 5}

  @doc "The limits used by `apply!/2` and `apply_error/2`."
  def limits, do: @limits

  @doc "Builds a State from `parse_create` params (a default name is filled in)."
  def state!(params \\ %{}) do
    {:ok, op} = Op.parse_create(Map.merge(%{"name" => "P&L 2026"}, params))
    limits = %{write_max_cells: 1_000}
    assert {:ok, state, _applied, _effects} = Engine.create(op, Ecto.UUID.generate(), limits)
    assert_consistent(state)
    state
  end

  @doc "Parses and applies an op map; asserts success. Returns `{state, applied, effects}`."
  def apply!(state, op_map, limits \\ @limits) do
    assert {:ok, op} = Op.parse(op_map)
    assert {:ok, new_state, applied, effects} = Engine.apply(state, op, limits)
    assert new_state.version == state.version + 1
    assert_consistent(new_state)
    {new_state, applied, effects}
  end

  @doc "Parses and applies an op map; asserts it fails. Returns `{code, message, meta}`."
  def apply_error(state, op_map, limits \\ @limits) do
    result =
      with {:ok, op} <- Op.parse(op_map), do: Engine.apply(state, op, limits)

    assert {:error, code, message, meta} = result
    {code, message, meta}
  end

  def column_id(state, name) do
    {:ok, column} = State.fetch_column_by_name(state, name)
    column.id
  end

  def row_id(state, label) do
    {:ok, row} = State.fetch_row_by_label(state, label)
    row.id
  end

  def labels(state), do: state |> State.rows() |> Enum.map(& &1.label)
  def column_names(state), do: state |> State.columns() |> Enum.map(& &1.name)

  @doc "A row's cells keyed by column name (label included), for readable assertions."
  def cells(state, label) do
    {:ok, row} = State.fetch_row_by_label(state, label)

    state
    |> State.row_cells(row)
    |> Map.new(fn {column_id, value} -> {state.columns_by_id[column_id].name, value} end)
  end

  @doc "Asserts that the order lists and all four indexes agree."
  def assert_consistent(%State{} = state) do
    columns = State.columns(state)
    rows = State.rows(state)

    assert length(state.column_order) == map_size(state.columns_by_id)
    assert Enum.sort(state.column_order) == Enum.sort(Map.keys(state.columns_by_id))

    assert state.column_id_by_name_key ==
             Map.new(columns, &{Key.normalize(&1.name), &1.id})

    assert [label_column] = Enum.filter(columns, & &1.is_label)
    assert label_column.id == state.label_column_id
    assert label_column.column_type == "text"

    assert length(state.row_order) == map_size(state.rows_by_id)
    assert Enum.sort(state.row_order) == Enum.sort(Map.keys(state.rows_by_id))
    assert state.row_id_by_label_key == Map.new(rows, &{Key.normalize(&1.label), &1.id})

    value_columns = MapSet.new(state.column_order) |> MapSet.delete(state.label_column_id)

    for row <- rows do
      assert row.label == String.trim(row.label) and row.label != ""
      assert MapSet.subset?(MapSet.new(Map.keys(row.values)), value_columns)
      refute Enum.any?(row.values, fn {_id, value} -> is_nil(value) end)
    end

    state
  end
end
