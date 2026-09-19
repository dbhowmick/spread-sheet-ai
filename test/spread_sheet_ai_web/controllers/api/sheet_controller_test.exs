defmodule SpreadSheetAiWeb.Api.SheetControllerTest do
  # `show` starts a sheet server, which shares the sandbox.
  use SpreadSheetAiWeb.ConnCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Repo
  alias SpreadSheetAi.Sheets.SheetQueries

  setup %{conn: conn} do
    user = verified_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "GET /api/sheets" do
    test "lists summaries, most recently updated first", %{conn: conn, user: user} do
      older =
        created_sheet_fixture(%{
          "name" => "Older",
          "columns" => [%{"name" => "Q1", "column_type" => "number"}],
          "rows" => [
            %{"label" => "Revenue", "values" => %{}},
            %{"label" => "Cost", "values" => %{}}
          ],
          owner: user
        })

      newer = created_sheet_fixture(%{"name" => "Newer"})

      backdated = DateTime.add(newer.updated_at, -60)
      Repo.update_all(SheetQueries.by_id(older.id), set: [updated_at: backdated])

      assert %{"sheets" => [first, second]} = conn |> get(~p"/api/sheets") |> json_response(200)
      assert first["id"] == newer.id

      assert second == %{
               "id" => older.id,
               "name" => "Older",
               "owner" => %{"id" => user.id, "display_name" => user.display_name},
               "row_count" => 2,
               "column_count" => 2,
               "version" => 1,
               "inserted_at" => DateTime.to_iso8601(older.inserted_at),
               "updated_at" => DateTime.to_iso8601(backdated)
             }
    end
  end

  describe "GET /api/sheets/:id" do
    test "returns the full sheet", %{conn: conn} do
      sheet =
        created_sheet_fixture(%{"rows" => [%{"label" => "Revenue", "values" => %{}}]})

      assert %{"sheet" => body} = conn |> get(~p"/api/sheets/#{sheet.id}") |> json_response(200)
      assert body["id"] == sheet.id
      assert body["version"] == 1
      assert [%{"name" => "Line item", "is_label" => true}] = body["columns"]
      assert [%{"cells" => cells}] = body["rows"]
      assert cells == %{sheet.label_column_id => "Revenue"}
    end

    test "is 404 for an unknown or malformed id", %{conn: conn} do
      for id <- [Ecto.UUID.generate(), "nope"] do
        assert %{"errors" => [%{"code" => "not_found"}]} =
                 conn |> get(~p"/api/sheets/#{id}") |> json_response(404)
      end
    end
  end

  describe "POST /api/sheets" do
    test "creates a sheet at version 1", %{conn: conn, user: user} do
      params = %{
        "name" => "P&L 2026",
        "label_column_name" => "Account",
        "columns" => [%{"name" => "Q1", "column_type" => "number"}],
        "rows" => [%{"label" => "Ignored", "values" => %{}}]
      }

      assert %{"sheet" => sheet} = conn |> post(~p"/api/sheets", params) |> json_response(201)

      assert %{"name" => "P&L 2026", "version" => 1, "rows" => []} = sheet
      assert sheet["owner"] == %{"id" => user.id, "display_name" => user.display_name}

      assert Enum.map(sheet["columns"], &{&1["name"], &1["column_type"], &1["is_label"]}) == [
               {"Account", "text", true},
               {"Q1", "number", false}
             ]
    end

    test "returns 422 validation_failed with the field", %{conn: conn} do
      assert %{"errors" => [error]} =
               conn |> post(~p"/api/sheets", %{"name" => "  "}) |> json_response(422)

      assert %{"code" => "validation_failed", "field" => "name"} = error

      assert %{"errors" => [%{"code" => "validation_failed", "field" => "columns"}]} =
               conn
               |> post(~p"/api/sheets", %{
                 "name" => "X",
                 "columns" => [%{"name" => "Q1", "column_type" => "currency"}]
               })
               |> json_response(422)
    end
  end

  test "every endpoint requires a session" do
    conn = build_conn()

    for conn <- [
          get(conn, ~p"/api/sheets"),
          get(conn, ~p"/api/sheets/#{Ecto.UUID.generate()}"),
          post(conn, ~p"/api/sheets", %{"name" => "X"})
        ] do
      assert %{"errors" => [%{"code" => "unauthenticated"}]} = json_response(conn, 401)
    end
  end
end
