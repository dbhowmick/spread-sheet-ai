defmodule SpreadSheetAiWeb.SocketToken do
  @moduledoc """
  Signs and verifies the short-lived token that authenticates a WebSocket
  connection. The SPA fetches it from `GET /api/socket_token` (authenticated
  by the auth cookie) and sends it as the Phoenix `auth_token`.

  The token only gates opening a connection; an open socket outlives it.
  """

  alias SpreadSheetAi.Accounts.Session
  alias SpreadSheetAiWeb.Endpoint

  @salt "user socket"
  @max_age 86_400

  @type claims :: %{user_id: Ecto.UUID.t(), session_id: Ecto.UUID.t()}

  @doc "Signs a token for `session`. `opts` go to `Phoenix.Token.sign/4`."
  @spec sign(Session.t(), keyword()) :: String.t()
  def sign(%Session{id: session_id, user_id: user_id}, opts \\ []) do
    Phoenix.Token.sign(Endpoint, @salt, %{user_id: user_id, session_id: session_id}, opts)
  end

  @spec verify(term()) :: {:ok, claims()} | {:error, :expired | :invalid | :missing}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_), do: {:error, :missing}
end
