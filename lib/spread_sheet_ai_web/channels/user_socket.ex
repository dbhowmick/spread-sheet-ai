defmodule SpreadSheetAiWeb.UserSocket do
  @moduledoc """
  The SPA's WebSocket. Authenticated by a `SpreadSheetAiWeb.SocketToken`
  sent as the Phoenix `auth_token` (the `Sec-WebSocket-Protocol` header),
  never in the URL. The session it names must still be active.
  """

  use Phoenix.Socket

  alias SpreadSheetAi.Accounts
  alias SpreadSheetAi.Accounts.Session
  alias SpreadSheetAiWeb.SocketToken

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    with {:ok, %{user_id: user_id, session_id: session_id}} <-
           SocketToken.verify(Map.get(connect_info, :auth_token)),
         %Session{user_id: ^user_id} = session <- Accounts.fetch_active_session(session_id) do
      Logger.metadata(user_id: user_id, session_id: session_id)

      {:ok,
       socket
       |> assign(:current_user, session.user)
       |> assign(:current_session, session)}
    else
      _ -> :error
    end
  end

  @impl Phoenix.Socket
  def id(socket), do: "user_socket:#{socket.assigns.current_session.id}"
end
