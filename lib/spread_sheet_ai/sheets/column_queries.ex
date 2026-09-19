defmodule SpreadSheetAi.Sheets.ColumnQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Sheets.Column`."

  import Ecto.Query

  alias SpreadSheetAi.Sheets.Column

  def for_sheet(query \\ Column, sheet_id) do
    where(query, [c], c.sheet_id == ^sheet_id)
  end

  def ordered(query \\ Column) do
    order_by(query, [c], asc: c.position)
  end
end
