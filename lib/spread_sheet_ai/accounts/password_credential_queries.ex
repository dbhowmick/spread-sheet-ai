defmodule SpreadSheetAi.Accounts.PasswordCredentialQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Accounts.PasswordCredential`."

  import Ecto.Query

  alias SpreadSheetAi.Accounts.PasswordCredential

  def for_user(query \\ PasswordCredential, user_id) do
    where(query, [c], c.user_id == ^user_id)
  end

  def by_reset_token_hash(query \\ PasswordCredential, hash) do
    where(query, [c], c.password_reset_token_hash == ^hash)
  end
end
