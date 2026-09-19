defmodule SpreadSheetAi.Sheets.ChangeQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Sheets.Change`."

  import Ecto.Query

  alias SpreadSheetAi.Sheets.Change

  def for_sheet(query \\ Change, sheet_id) do
    where(query, [ch], ch.sheet_id == ^sheet_id)
  end

  def ordered(query \\ Change) do
    order_by(query, [ch], asc: ch.version)
  end
end
