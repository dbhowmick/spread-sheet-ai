defmodule SpreadSheetAi.Accounts.Scope do
  @moduledoc """
  The caller identity passed to Sagents-generated code (conversations,
  coordinator). Wraps the signed-in `User`.
  """

  alias SpreadSheetAi.Accounts.User

  defstruct [:user]

  @type t :: %__MODULE__{user: User.t() | nil}

  @spec for_user(User.t()) :: t()
  def for_user(%User{} = user), do: %__MODULE__{user: user}
end
