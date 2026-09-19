defmodule SpreadSheetAi.Accounts.SessionQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Accounts.Session`."

  import Ecto.Query

  alias SpreadSheetAi.Accounts.Session

  def by_id(query \\ Session, id) do
    where(query, [s], s.id == ^id)
  end

  def by_token_hash(query \\ Session, hash) do
    where(query, [s], s.token_hash == ^hash)
  end

  def for_user(query \\ Session, user_id) do
    where(query, [s], s.user_id == ^user_id)
  end

  def active(query \\ Session) do
    now = DateTime.utc_now()
    where(query, [s], is_nil(s.revoked_at) and s.expires_at > ^now)
  end

  @doc "Joins the session's user, keeps only active users, and preloads it."
  def with_active_user(query \\ Session) do
    from s in query,
      join: u in assoc(s, :user),
      where: u.status == "active",
      preload: [user: u]
  end

  def expired(query \\ Session, cutoff_at) do
    where(query, [s], s.expires_at < ^cutoff_at)
  end

  def by_id_for_user(query \\ Session, id, user_id) do
    where(query, [s], s.id == ^id and s.user_id == ^user_id)
  end

  def paginate(query, page, page_size) do
    query |> limit(^page_size) |> offset(^((page - 1) * page_size))
  end
end
