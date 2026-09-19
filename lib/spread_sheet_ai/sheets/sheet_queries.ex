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
end
