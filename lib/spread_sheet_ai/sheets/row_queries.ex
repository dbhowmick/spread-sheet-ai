defmodule SpreadSheetAi.Sheets.RowQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Sheets.Row`."

  import Ecto.Query

  alias SpreadSheetAi.Sheets.Row

  def for_sheet(query \\ Row, sheet_id) do
    where(query, [r], r.sheet_id == ^sheet_id)
  end

  def by_id(query \\ Row, id) do
    where(query, [r], r.id == ^id)
  end

  def by_ids(query \\ Row, ids) do
    where(query, [r], r.id in ^ids)
  end

  def ordered(query \\ Row) do
    order_by(query, [r], asc: r.position)
  end
end
