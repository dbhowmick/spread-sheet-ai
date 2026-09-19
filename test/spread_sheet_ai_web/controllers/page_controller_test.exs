defmodule SpreadSheetAiWeb.PageControllerTest do
  use SpreadSheetAiWeb.ConnCase

  test "GET / renders the SPA shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ ~s(<div id="app">)
    assert body =~ ~s(<meta name="csrf-token")
  end

  test "GET /deep/spa/route also renders the shell (vue-router fallback)", %{conn: conn} do
    conn = get(conn, "/some/deep/route")
    assert html_response(conn, 200) =~ ~s(<div id="app">)
  end
end
