defmodule SpreadSheetAiWeb.Api.ConversationControllerTest do
  use SpreadSheetAiWeb.ConnCase, async: true

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures

  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Conversations

  setup %{conn: conn} do
    user = verified_user_fixture(%{display_name: "Alice"})
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "GET /api/conversations" do
    test "lists every user's conversations, most recent activity first (CS-1)", %{
      conn: conn,
      user: user
    } do
      bob = verified_user_fixture(%{display_name: "Bob"})
      older = conversation_fixture(bob, %{title: "Older"})
      newer = conversation_fixture(user)

      # A message is activity: it moves the older conversation to the top.
      {:ok, _message} =
        Conversations.append_text_message(Scope.for_user(bob), older.id, "user", "hi")

      assert %{"conversations" => [first, second]} =
               conn |> get(~p"/api/conversations") |> json_response(200)

      assert %{
               "id" => older_id,
               "title" => "Older",
               "created_by" => %{"id" => bob_id, "display_name" => "Bob"},
               "inserted_at" => _,
               "updated_at" => _
             } = first

      assert older_id == older.id
      assert bob_id == bob.id
      assert second["id"] == newer.id
    end
  end

  describe "POST /api/conversations" do
    test "creates an untitled conversation for the caller", %{conn: conn, user: user} do
      assert %{"conversation" => conversation} =
               conn |> post(~p"/api/conversations", %{}) |> json_response(201)

      assert %{"title" => nil, "created_by" => %{"id" => user_id}} = conversation
      assert user_id == user.id

      assert {:ok, %{user_id: ^user_id}} =
               Conversations.get_conversation(Scope.for_user(user), conversation["id"])
    end
  end

  describe "GET /api/conversations/:id" do
    test "returns the summary", %{conn: conn} do
      conversation = conversation_fixture(verified_user_fixture(), %{title: "Budget"})

      assert %{"conversation" => %{"id" => id, "title" => "Budget"}} =
               conn |> get(~p"/api/conversations/#{conversation.id}") |> json_response(200)

      assert id == conversation.id
    end

    @tag :capture_log
    test "an unknown or malformed id is not_found", %{conn: conn} do
      for id <- [Ecto.UUID.generate(), "nope"] do
        assert %{"errors" => [%{"code" => "not_found"}]} =
                 conn |> get(~p"/api/conversations/#{id}") |> json_response(404)
      end
    end
  end

  test "every endpoint requires a session" do
    conn = build_conn()

    for conn <- [
          get(conn, ~p"/api/conversations"),
          get(conn, ~p"/api/conversations/#{Ecto.UUID.generate()}"),
          post(conn, ~p"/api/conversations", %{})
        ] do
      assert %{"errors" => [%{"code" => "unauthenticated"}]} = json_response(conn, 401)
    end
  end
end
