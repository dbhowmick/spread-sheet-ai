defmodule SpreadSheetAiWeb.UserSocketTest do
  use SpreadSheetAiWeb.ChannelCase, async: true

  alias SpreadSheetAi.Accounts.{Session, User}
  alias SpreadSheetAi.AuthFixtures
  alias SpreadSheetAi.Repo
  alias SpreadSheetAiWeb.{SocketToken, UserSocket}

  setup do
    user = AuthFixtures.verified_user_fixture()
    %{session: session} = AuthFixtures.session_fixture(user)
    %{user: user, session: session}
  end

  defp connect_with(token) do
    connect(UserSocket, %{}, connect_info: %{auth_token: token})
  end

  test "connects with a valid token", %{user: user, session: session} do
    assert {:ok, socket} = connect_with(SocketToken.sign(session))

    assert socket.assigns.current_user.id == user.id
    assert socket.assigns.current_session.id == session.id
    assert UserSocket.id(socket) == "user_socket:#{session.id}"
  end

  test "connect_user/1 connects a fresh session", %{user: user} do
    assert {:ok, socket} = connect_user(user)
    assert socket.assigns.current_user.id == user.id
  end

  test "refuses a connection without a token" do
    assert :error = connect(UserSocket, %{})
  end

  test "refuses a garbage token" do
    assert :error = connect_with("not-a-token")
  end

  test "refuses a token signed with another salt", %{session: session} do
    token =
      Phoenix.Token.sign(@endpoint, "other salt", %{
        user_id: session.user_id,
        session_id: session.id
      })

    assert :error = connect_with(token)
  end

  test "refuses a token older than 24 hours", %{session: session} do
    signed_at = System.system_time(:second) - 86_401
    assert :error = connect_with(SocketToken.sign(session, signed_at: signed_at))
  end

  test "refuses a token whose user does not own the session", %{session: session} do
    other = AuthFixtures.verified_user_fixture()

    token =
      Phoenix.Token.sign(@endpoint, "user socket", %{user_id: other.id, session_id: session.id})

    assert :error = connect_with(token)
  end

  test "refuses a deleted session", %{session: session} do
    token = SocketToken.sign(session)
    Repo.delete!(session)

    assert :error = connect_with(token)
  end

  test "refuses a revoked session", %{session: session} do
    token = SocketToken.sign(session)
    session |> Session.changeset(%{revoked_at: now()}) |> Repo.update!()

    assert :error = connect_with(token)
  end

  test "refuses an expired session", %{session: session} do
    token = SocketToken.sign(session)
    session |> Session.changeset(%{expires_at: DateTime.add(now(), -60)}) |> Repo.update!()

    assert :error = connect_with(token)
  end

  test "refuses an inactive user", %{user: user, session: session} do
    token = SocketToken.sign(session)
    user |> User.changeset(%{status: "suspended"}) |> Repo.update!()

    assert :error = connect_with(token)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
