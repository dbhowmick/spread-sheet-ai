defmodule SpreadSheetAiWeb.Api.SheetController do
  use SpreadSheetAiWeb, :controller

  alias SpreadSheetAi.Sheets
  alias SpreadSheetAiWeb.SheetJSON

  action_fallback SpreadSheetAiWeb.Api.FallbackController

  # The contract §3 create fields; `rows` is only for the AI's create_sheet tool.
  @create_fields ["name", "label_column_name", "columns"]

  # GET /api/sheets — every sheet, most recently updated first.
  def index(conn, _params) do
    json(conn, %{sheets: Enum.map(Sheets.list_sheets(), &SheetJSON.summary/1)})
  end

  # GET /api/sheets/:id — the full snapshot, for the first load of a page.
  def show(conn, %{"id" => id}) do
    with {:ok, state} <- Sheets.snapshot(id) do
      json(conn, %{sheet: SheetJSON.sheet(state)})
    end
  end

  # POST /api/sheets — a new sheet at version 1, owned by the caller.
  def create(conn, params) do
    with {:ok, state} <-
           Sheets.create_sheet(Map.take(params, @create_fields), conn.assigns.current_user) do
      conn
      |> put_status(:created)
      |> json(%{sheet: SheetJSON.sheet(state)})
    end
  end
end
