defmodule SpreadSheetAi.Sheets.Engine do
  @moduledoc """
  The pure sheet engine. It validates an op against contract §6, applies it
  to a `SpreadSheetAi.Sheets.State`, and describes the database writes as
  effects. It has no side effects apart from generating ids for new sheets,
  columns and rows.

  `apply/3` returns `{:ok, new_state, applied_op, effects}`, where
  `new_state.version` is one higher (OP-3) and `applied_op` is the
  string-keyed contract `AppliedOp`, or `{:error, code, message, meta}`
  with a contract §8 code. Every check runs before anything is built, so an
  op applies in full or not at all (OP-1).

  Effects (run in order by the Persister):

    * `{:insert_sheet, attrs}`, `{:update_sheet, %{name}}`
    * `{:insert_column, attrs}`, `{:insert_columns, [attrs]}`,
      `{:update_column, id, fields}`, `{:delete_column, id}`,
      `{:remove_column_values, column_id}`
    * `{:insert_rows, [attrs]}`, `{:update_row, id, fields}`,
      `{:delete_rows, ids}`
    * `{:set_positions, :columns | :rows, [{id, position}]}` — only the ids
      whose index changed

  Row `fields` carry the full new `values` map. The version bump and the
  change-log row are the Persister's job, not effects.
  """

  alias SpreadSheetAi.Sheets.Engine.{Checks, Columns, Rows}
  alias SpreadSheetAi.Sheets.{Key, Op, State}

  @type limits :: %{:write_max_cells => pos_integer(), optional(atom()) => term()}
  @type effect :: tuple()
  @type error :: {:error, atom(), String.t(), map()}
  @type result :: {:ok, State.t(), map(), [effect()]} | error()

  @doc "Applies `op` to `state`. See the module doc for the result."
  @spec apply(State.t(), Op.t(), limits()) :: result()
  def apply(%State{} = state, op, limits) do
    with {:ok, new_state, applied, effects} <- do_apply(state, op, limits) do
      {:ok, %{new_state | version: state.version + 1}, applied, effects}
    end
  end

  defp do_apply(state, %Op.RenameSheet{name: name}, _limits) do
    with {:ok, name} <- Checks.name(name, "sheet name") do
      {:ok, %{state | name: name}, %{"type" => "rename_sheet", "name" => name},
       [{:update_sheet, %{name: name}}]}
    end
  end

  defp do_apply(state, %Op.AddColumn{} = op, _limits), do: Columns.add(state, op)
  defp do_apply(state, %Op.RenameColumn{} = op, _limits), do: Columns.rename(state, op)
  defp do_apply(state, %Op.ChangeColumnType{} = op, _limits), do: Columns.change_type(state, op)
  defp do_apply(state, %Op.MoveColumn{} = op, _limits), do: Columns.move(state, op)
  defp do_apply(state, %Op.DeleteColumn{} = op, _limits), do: Columns.delete(state, op)
  defp do_apply(state, %Op.AddRows{} = op, limits), do: Rows.add(state, op, limits)
  defp do_apply(state, %Op.DeleteRows{} = op, _limits), do: Rows.delete(state, op)
  defp do_apply(state, %Op.MoveRow{} = op, _limits), do: Rows.move(state, op)
  defp do_apply(state, %Op.SetCells{} = op, limits), do: Rows.set_cells(state, op, limits)

  @doc """
  Builds a new sheet at version 1: the text label column first, then the
  given columns in order, then the given rows (their `values` keyed by
  column name). Returns `{:ok, state, applied_op, effects}`; the applied op
  (`"type" => "create_sheet"`) is the first change-log entry.
  """
  @spec create(Op.CreateSheet.t(), Ecto.UUID.t(), limits()) :: result()
  def create(%Op.CreateSheet{} = op, owner_id, limits) do
    with {:ok, name} <- Checks.name(op.name, "sheet name", :validation_failed, %{field: "name"}),
         {:ok, label_name} <-
           Checks.name(op.label_column_name, "label column name", :validation_failed, %{
             field: "label_column_name"
           }),
         :ok <- Checks.within_cap(length(op.rows), limits, "rows"),
         {:ok, state} <-
           build_columns(
             State.new(Ecto.UUID.generate(), name, owner_id, 1),
             label_name,
             op.columns
           ),
         {:ok, new_rows} <- rows_by_column_id(state, op.rows),
         {:ok, rows} <- Rows.build_rows(state, new_rows) do
      state = State.insert_rows(state, rows, 0)
      {:ok, state, created_op(state), created_effects(state, rows)}
    end
  end

  defp build_columns(state, label_name, columns) do
    label = %{id: Ecto.UUID.generate(), name: label_name, column_type: "text", is_label: true}

    Enum.reduce_while(columns, {:ok, State.insert_columns(state, [label], 0)}, fn column,
                                                                                  {:ok, acc} ->
      with {:ok, name} <-
             Checks.name(column.name, "column name", :validation_failed, %{field: "columns"}),
           :ok <- Checks.unique_column_name(acc, name) do
        new = %{
          id: Ecto.UUID.generate(),
          name: name,
          column_type: column.column_type,
          is_label: false
        }

        {:cont, {:ok, State.insert_columns(acc, [new], length(acc.column_order))}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Turns `%{label, values: %{column_name => value}}` into the
  # `%{id, cells: %{column_id => value}}` shape `Rows.build_rows/2` takes.
  # The row's `label` wins over a value keyed by the label column's name.
  defp rows_by_column_id(state, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case cells_by_column_id(state, row.values) do
        {:ok, cells} ->
          {:cont,
           {:ok, [%{id: nil, cells: Map.put(cells, state.label_column_id, row.label)} | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp cells_by_column_id(state, values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, value}, {:ok, cells} ->
      case State.fetch_column_by_name(state, name) do
        {:ok, column} ->
          {:cont, {:ok, Map.put(cells, column.id, value)}}

        :error ->
          {:halt, {:error, :unknown_column, "column \"#{name}\" does not exist", %{column: name}}}
      end
    end)
  end

  defp created_op(state) do
    %{
      "type" => "create_sheet",
      "name" => state.name,
      "columns" =>
        Enum.map(State.columns(state), fn column ->
          %{
            "id" => column.id,
            "name" => column.name,
            "column_type" => column.column_type,
            "is_label" => column.is_label
          }
        end),
      "rows" =>
        Enum.map(State.rows(state), &%{"id" => &1.id, "cells" => State.row_cells(state, &1)})
    }
  end

  defp created_effects(state, rows) do
    columns =
      state
      |> State.columns()
      |> Enum.with_index()
      |> Enum.map(fn {column, position} ->
        Map.merge(column, %{name_key: Key.normalize(column.name), position: position})
      end)

    [
      {:insert_sheet, %{id: state.id, name: state.name, owner_id: state.owner_id, version: 1}},
      {:insert_columns, columns}
    ] ++ if(rows == [], do: [], else: [{:insert_rows, Rows.row_attrs(rows, 0)}])
  end
end
