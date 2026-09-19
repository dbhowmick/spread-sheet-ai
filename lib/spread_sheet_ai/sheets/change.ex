defmodule SpreadSheetAi.Sheets.Change do
  @moduledoc """
  One entry in a sheet's change log: the `AppliedOp` that produced
  `version`, and who made it. A user change has `actor_user_id`; an agent
  change has `conversation_id` (a user change may also have one when it was
  made inside a conversation).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.Sheets.Sheet

  @type t :: %__MODULE__{}

  @actor_types ~w(user agent)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "sheet_changes" do
    field :version, :integer
    field :op, :map
    field :actor_type, :string
    field :conversation_id, Ecto.UUID
    field :client_op_id, Ecto.UUID

    belongs_to :sheet, Sheet
    belongs_to :actor_user, User

    timestamps()
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :sheet_id,
      :version,
      :op,
      :actor_type,
      :actor_user_id,
      :conversation_id,
      :client_op_id
    ])
    |> validate_required([:sheet_id, :version, :op, :actor_type])
    |> validate_inclusion(:actor_type, @actor_types)
    |> validate_actor()
    |> unique_constraint(:version, name: :sheet_changes_sheet_id_version_index)
    |> check_constraint(:actor_type, name: :sheet_changes_actor_type_check)
    |> foreign_key_constraint(:sheet_id)
    |> foreign_key_constraint(:actor_user_id)
  end

  defp validate_actor(changeset) do
    case get_field(changeset, :actor_type) do
      "user" -> validate_required(changeset, [:actor_user_id])
      "agent" -> validate_required(changeset, [:conversation_id])
      _ -> changeset
    end
  end
end
