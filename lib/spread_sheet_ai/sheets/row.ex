defmodule SpreadSheetAi.Sheets.Row do
  @moduledoc """
  A sheet row (a line item). `label` is the label column's value and is
  unique per sheet, trimmed and case-insensitive, via `label_key`. `values`
  holds the other cells as `%{column_id => value}`; empty cells are left
  out.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SpreadSheetAi.Sheets.{Key, Sheet}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sheet_rows" do
    field :label, :string
    field :label_key, :string
    field :position, :integer
    field :values, :map, default: %{}

    belongs_to :sheet, Sheet
  end

  @doc "The uniqueness key for a row label."
  defdelegate label_key(label), to: Key, as: :normalize

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:id, :sheet_id, :label, :position, :values])
    |> validate_required([:sheet_id, :label, :position, :values])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> Key.put_key(:label, :label_key)
    |> unique_constraint(:label, name: :sheet_rows_sheet_id_label_key_index)
    |> foreign_key_constraint(:sheet_id)
  end
end
