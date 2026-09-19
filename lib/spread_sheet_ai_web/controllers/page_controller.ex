defmodule SpreadSheetAiWeb.PageController do
  use SpreadSheetAiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
