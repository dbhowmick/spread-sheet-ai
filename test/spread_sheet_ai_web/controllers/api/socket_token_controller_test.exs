defmodule SpreadSheetAiWeb.Api.SocketTokenControllerTest do
  use SpreadSheetAiWeb.ConnCase, async: true

  alias SpreadSheetAi.Auth.Config
  alias SpreadSheetAi.AuthFixtures
  alias SpreadSheetAiWeb.SocketToken

  describe "GET /api/socket_token" do
    test "returns a token for the current session", %{conn: conn} do
      user = AuthFixtures.verified_user_fixture()
      %{session: session, raw_token: raw_token} = AuthFixtures.session_fixture(user)

      conn =
        conn
        |> put_req_cookie(Config.session_cookie_name(), raw_token)
        |> get(~p"/api/socket_token")

      token = json_response(conn, 200)["token"]

      assert {:ok, %{user_id: user_id, session_id: session_id}} = SocketToken.verify(token)
      assert user_id == user.id
      assert session_id == session.id
    end

    test "returns 401 without a session", %{conn: conn} do
      conn = get(conn, ~p"/api/socket_token")

      assert json_response(conn, 401)["errors"] |> hd() |> Map.fetch!("code") ==
               "unauthenticated"
    end
  end
end
