defmodule SpreadSheetAiWeb.ChannelCase do
  @moduledoc """
  Test case for socket and channel tests. Sets up the SQL sandbox and
  provides `connect_user/1`, which signs a socket token for a fresh session
  of the given user and connects `SpreadSheetAiWeb.UserSocket` with it.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import SpreadSheetAiWeb.ChannelCase

      @endpoint SpreadSheetAiWeb.Endpoint
    end
  end

  setup tags do
    SpreadSheetAi.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Connects `SpreadSheetAiWeb.UserSocket` as `user` through a new session.
  Returns `{:ok, socket}` (or `:error`, if the connect is refused).
  """
  defmacro connect_user(user) do
    quote do
      %{session: session} = SpreadSheetAi.AuthFixtures.session_fixture(unquote(user))
      token = SpreadSheetAiWeb.SocketToken.sign(session)
      connect(SpreadSheetAiWeb.UserSocket, %{}, connect_info: %{auth_token: token})
    end
  end
end
