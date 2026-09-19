defmodule SpreadSheetAi.Sheets.Actor do
  @moduledoc """
  Who made a change (contract §2.7): a signed-in user, or the AI agent of a
  conversation. A user change made inside a conversation also carries that
  `conversation_id`. It is written to the change log and broadcast with
  every applied op.
  """

  alias SpreadSheetAi.Accounts.User

  @type t :: %__MODULE__{
          type: :user | :agent,
          user: User.t() | nil,
          conversation_id: Ecto.UUID.t() | nil,
          conversation_title: String.t() | nil
        }

  @enforce_keys [:type]
  defstruct [:type, :user, :conversation_id, :conversation_title]

  @spec user(User.t(), Ecto.UUID.t() | nil) :: t()
  def user(%User{} = user, conversation_id \\ nil),
    do: %__MODULE__{type: :user, user: user, conversation_id: conversation_id}

  @spec agent(Ecto.UUID.t(), String.t() | nil) :: t()
  def agent(conversation_id, title) when is_binary(conversation_id),
    do: %__MODULE__{type: :agent, conversation_id: conversation_id, conversation_title: title}

  @doc "The actor fields of a `SpreadSheetAi.Sheets.Change` row."
  @spec change_attrs(t()) :: map()
  def change_attrs(%__MODULE__{} = actor) do
    %{
      actor_type: Atom.to_string(actor.type),
      actor_user_id: actor.user && actor.user.id,
      conversation_id: actor.conversation_id
    }
  end
end
