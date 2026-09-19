defmodule SpreadSheetAiWeb.Api.ConversationController do
  use SpreadSheetAiWeb, :controller

  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Conversations
  alias SpreadSheetAiWeb.ConversationJSON

  action_fallback SpreadSheetAiWeb.Api.FallbackController

  # GET /api/conversations — every conversation (they are shared, CS-1),
  # most recent activity first.
  def index(conn, _params) do
    conversations = Conversations.list_conversations(scope(conn))
    json(conn, %{conversations: Enum.map(conversations, &ConversationJSON.summary/1)})
  end

  # POST /api/conversations — a new, untitled conversation created by the
  # caller. The body is ignored.
  def create(conn, _params) do
    with {:ok, conversation} <- Conversations.create_conversation(scope(conn), %{}) do
      conn
      |> put_status(:created)
      |> json(%{
        conversation: ConversationJSON.summary(%{conversation | user: conn.assigns.current_user})
      })
    end
  end

  # GET /api/conversations/:id — the summary, for the first load of a page.
  # Messages and linked sheets come with the channel join.
  def show(conn, %{"id" => id}) do
    with {:ok, conversation} <- Conversations.get_conversation(scope(conn), id) do
      json(conn, %{conversation: ConversationJSON.summary(conversation)})
    end
  end

  defp scope(conn), do: Scope.for_user(conn.assigns.current_user)
end
