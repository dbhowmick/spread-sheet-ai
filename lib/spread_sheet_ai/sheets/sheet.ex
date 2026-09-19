defmodule SpreadSheetAi.Sheets.Sheet do
  @moduledoc """
  A sheet: a named table of line items. `version` goes up by one for every
  applied op; the change log in `SpreadSheetAi.Sheets.Change` records each
  one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.Sheets.{Column, Row}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "sheets" do
    field :name, :string
    field :version, :integer, default: 0

    belongs_to :owner, User
    has_many :columns, Column
    has_many :rows, Row

    timestamps()
  end

  @doc "Changeset for a new sheet."
  def create_changeset(sheet, attrs) do
    sheet
    |> cast(attrs, [:name, :owner_id])
    |> validate_required([:name, :owner_id])
    |> foreign_key_constraint(:owner_id)
  end
end
