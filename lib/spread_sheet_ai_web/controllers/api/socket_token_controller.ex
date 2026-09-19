defmodule SpreadSheetAiWeb.Api.SocketTokenController do
  use SpreadSheetAiWeb, :controller

  alias SpreadSheetAiWeb.SocketToken

  action_fallback SpreadSheetAiWeb.Api.FallbackController

  # GET /api/socket_token — a token for opening the WebSocket (contract §4).
  def show(conn, _params) do
    json(conn, %{token: SocketToken.sign(conn.assigns.current_session)})
  end
end
