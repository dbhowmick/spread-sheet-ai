defmodule SpreadSheetAi.Sheets.Column do
  @moduledoc """
  A sheet column. Exactly one column per sheet is the label column
  (`is_label`), which is always `text` and holds each row's label. Names are
  unique per sheet, trimmed and case-insensitive, via `name_key`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SpreadSheetAi.Sheets.{Key, Sheet}

  @type t :: %__MODULE__{}

  @types ~w(text number boolean date)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sheet_columns" do
    field :name, :string
    field :name_key, :string
    field :column_type, :string
    field :is_label, :boolean, default: false
    field :position, :integer

    belongs_to :sheet, Sheet
  end

  @doc "The column types, as stored in `column_type`."
  def types, do: @types

  @doc "The uniqueness key for a column name."
  defdelegate name_key(name), to: Key, as: :normalize

  def changeset(column, attrs) do
    column
    |> cast(attrs, [:id, :sheet_id, :name, :column_type, :is_label, :position])
    |> validate_required([:sheet_id, :name, :column_type, :position])
    |> validate_inclusion(:column_type, @types)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> Key.put_key(:name, :name_key)
    |> unique_constraint(:name, name: :sheet_columns_sheet_id_name_key_index)
    |> unique_constraint(:is_label, name: :sheet_columns_one_label_per_sheet_index)
    |> check_constraint(:column_type, name: :sheet_columns_column_type_check)
    |> check_constraint(:column_type, name: :sheet_columns_label_is_text_check)
    |> foreign_key_constraint(:sheet_id)
  end
end
