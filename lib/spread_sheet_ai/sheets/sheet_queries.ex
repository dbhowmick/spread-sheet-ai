defmodule SpreadSheetAi.Sheets.SheetQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Sheets.Sheet`."

  import Ecto.Query

  alias SpreadSheetAi.Sheets.Sheet

  def by_id(query \\ Sheet, id) do
    where(query, [s], s.id == ^id)
  end

  def with_version(query \\ Sheet, version) do
    where(query, [s], s.version == ^version)
  end

  def newest_first(query \\ Sheet) do
    order_by(query, [s], desc: s.updated_at, desc: s.id)
  end

  def with_owner(query \\ Sheet) do
    preload(query, :owner)
  end

  @doc "Selects `%{sheet: sheet, row_count: n, column_count: n}`."
  def with_counts(query \\ Sheet) do
    select(query, [s], %{
      sheet: s,
      row_count: fragment("(SELECT count(*) FROM sheet_rows r WHERE r.sheet_id = ?)", s.id),
      column_count: fragment("(SELECT count(*) FROM sheet_columns c WHERE c.sheet_id = ?)", s.id)
    })
  end
end
