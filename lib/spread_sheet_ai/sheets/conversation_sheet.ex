defmodule SpreadSheetAi.Sheets.ConversationSheet do
  @moduledoc """
  A link between a conversation and a sheet it used (ST-1). There is one
  link per pair: `SpreadSheetAi.Sheets.link/3` upserts it, keeping
  `first_accessed_at`, updating `last_access` and `last_accessed_at`, and
  OR-ing `created_here`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SpreadSheetAi.Conversations.Conversation
  alias SpreadSheetAi.Sheets.Sheet

  @type t :: %__MODULE__{}

  @access_kinds ~w(created opened read written)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_sheets" do
    field :created_here, :boolean, default: false
    field :last_access, :string
    field :first_accessed_at, :utc_datetime
    field :last_accessed_at, :utc_datetime

    belongs_to :conversation, Conversation
    belongs_to :sheet, Sheet
  end

  @doc "The `last_access` values."
  def access_kinds, do: @access_kinds

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :conversation_id,
      :sheet_id,
      :created_here,
      :last_access,
      :first_accessed_at,
      :last_accessed_at
    ])
    |> validate_required([
      :conversation_id,
      :sheet_id,
      :last_access,
      :first_accessed_at,
      :last_accessed_at
    ])
    |> validate_inclusion(:last_access, @access_kinds)
    |> check_constraint(:last_access, name: :conversation_sheets_last_access_check)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:sheet_id)
  end
end
