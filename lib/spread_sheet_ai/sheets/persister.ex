defmodule SpreadSheetAi.Sheets.Persister do
  @moduledoc """
  Writes the engine's effects (see `SpreadSheetAi.Sheets.Engine`) to
  Postgres, together with the version bump and the change-log row, in one
  transaction (P-2, P-3).

  `apply/6` bumps the version first with
  `UPDATE sheets SET version = version + 1 … WHERE id = ? AND version = ?`,
  which both locks the sheet row and fails with `:version_conflict` when the
  caller's in-memory version is out of step with the database.

  The `(sheet_id, label_key)` unique index is not deferrable, so when an op
  relabels two or more rows (which may swap labels), their `label_key`s are
  first set to a temporary `" " <> id`. A normalized label is trimmed, so it
  never starts with a space and can't collide with a temporary key.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SpreadSheetAi.Repo
  alias SpreadSheetAi.Sheets.{Actor, Change, Column, ColumnQueries, Engine}
  alias SpreadSheetAi.Sheets.{Row, RowQueries, Sheet, SheetQueries}

  @type error :: {:error, term()}

  @doc """
  Persists a new sheet: the `Engine.create/3` effects and the change-log
  row for version 1. Returns the sheet's timestamps.
  """
  @spec create([Engine.effect()], map(), Actor.t()) ::
          {:ok, %{inserted_at: DateTime.t(), updated_at: DateTime.t()}} | error()
  def create([{:insert_sheet, %{id: sheet_id}} | _] = effects, applied_op, %Actor{} = actor) do
    Multi.new()
    |> effects(sheet_id, effects)
    |> change(sheet_id, 1, applied_op, actor, [])
    |> run(fn %{sheet: sheet} ->
      %{inserted_at: sheet.inserted_at, updated_at: sheet.updated_at}
    end)
  end

  @doc """
  Persists an applied op that produced `version`: bumps the sheet from
  `version - 1`, runs the effects and adds the change-log row. `opts` takes
  `:client_op_id`. Returns the `updated_at` it wrote.
  """
  @spec apply(Ecto.UUID.t(), pos_integer(), [Engine.effect()], map(), Actor.t(), keyword()) ::
          {:ok, DateTime.t()} | error()
  def apply(sheet_id, version, effects, applied_op, %Actor{} = actor, opts \\ []) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:bump, fn repo, _changes -> bump(repo, sheet_id, version - 1, now) end)
    |> stage_label_keys(effects)
    |> effects(sheet_id, effects)
    |> change(sheet_id, version, applied_op, actor, opts)
    |> run(fn _changes -> now end)
  end

  defp run(multi, on_success) do
    case Repo.transaction(multi) do
      {:ok, changes} -> {:ok, on_success.(changes)}
      {:error, _step, :version_conflict, _changes} -> {:error, :version_conflict}
      {:error, step, reason, _changes} -> {:error, {step, reason}}
    end
  end

  defp bump(repo, sheet_id, from_version, now) do
    query = sheet_id |> SheetQueries.by_id() |> SheetQueries.with_version(from_version)

    case repo.update_all(query, inc: [version: 1], set: [updated_at: now]) do
      {1, _} -> {:ok, from_version + 1}
      {0, _} -> {:error, :version_conflict}
    end
  end

  defp stage_label_keys(multi, effects) do
    relabelled = for {:update_row, id, %{label_key: _}} <- effects, do: id

    if length(relabelled) < 2 do
      multi
    else
      query =
        relabelled
        |> RowQueries.by_ids()
        |> update([r], set: [label_key: fragment("' ' || ?::text", r.id)])

      Multi.update_all(multi, :stage_label_keys, query, [])
    end
  end

  defp change(multi, sheet_id, version, applied_op, actor, opts) do
    attrs =
      actor
      |> Actor.change_attrs()
      |> Map.merge(%{
        sheet_id: sheet_id,
        version: version,
        op: applied_op,
        client_op_id: Keyword.get(opts, :client_op_id)
      })

    Multi.insert(multi, :change, Change.changeset(%Change{}, attrs))
  end

  defp effects(multi, sheet_id, effects) do
    effects
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {effect, index}, acc ->
      effect(acc, {:effect, index}, sheet_id, effect)
    end)
  end

  defp effect(multi, _name, _sheet_id, {:insert_sheet, attrs}) do
    sheet = %Sheet{id: attrs.id, version: attrs.version}
    Multi.insert(multi, :sheet, Sheet.create_changeset(sheet, attrs))
  end

  defp effect(multi, name, sheet_id, {:update_sheet, fields}),
    do: Multi.update_all(multi, name, SheetQueries.by_id(sheet_id), set: Map.to_list(fields))

  defp effect(multi, name, sheet_id, {:insert_column, attrs}),
    do: effect(multi, name, sheet_id, {:insert_columns, [attrs]})

  defp effect(multi, name, sheet_id, {:insert_columns, columns}),
    do: Multi.insert_all(multi, name, Column, with_sheet_id(columns, sheet_id))

  defp effect(multi, name, _sheet_id, {:update_column, id, fields}),
    do: Multi.update_all(multi, name, ColumnQueries.by_id(id), set: Map.to_list(fields))

  defp effect(multi, name, _sheet_id, {:delete_column, id}),
    do: Multi.delete_all(multi, name, ColumnQueries.by_id(id))

  defp effect(multi, name, sheet_id, {:remove_column_values, column_id}) do
    query =
      sheet_id
      |> RowQueries.for_sheet()
      |> update([r], set: [values: fragment("? - ?", r.values, ^column_id)])

    Multi.update_all(multi, name, query, [])
  end

  defp effect(multi, name, sheet_id, {:insert_rows, rows}),
    do: Multi.insert_all(multi, name, Row, with_sheet_id(rows, sheet_id))

  defp effect(multi, name, _sheet_id, {:update_row, id, fields}),
    do: Multi.update_all(multi, name, RowQueries.by_id(id), set: Map.to_list(fields))

  defp effect(multi, name, _sheet_id, {:delete_rows, ids}),
    do: Multi.delete_all(multi, name, RowQueries.by_ids(ids))

  defp effect(multi, name, _sheet_id, {:set_positions, :columns, positions}),
    do: Multi.update_all(multi, name, positions_query(Column, positions), [])

  defp effect(multi, name, _sheet_id, {:set_positions, :rows, positions}),
    do: Multi.update_all(multi, name, positions_query(Row, positions), [])

  # One UPDATE … FROM unnest(ids, positions) for every moved id.
  defp positions_query(schema, positions) do
    {ids, indexes} = Enum.unzip(positions)

    from(x in schema,
      join:
        p in fragment(
          "SELECT * FROM unnest(?::uuid[], ?::integer[]) AS p(id, position)",
          type(^ids, {:array, :binary_id}),
          ^indexes
        ),
      on: x.id == p.id,
      update: [set: [position: p.position]]
    )
  end

  defp with_sheet_id(entries, sheet_id), do: Enum.map(entries, &Map.put(&1, :sheet_id, sheet_id))
end
