defmodule SpreadSheetAi.Repo.Migrations.CreateSheetColumns do
  use Ecto.Migration

  def change do
    create table(:sheet_columns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sheet_id, references(:sheets, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :text, null: false
      # lower(trim(name)), computed in Elixir — see SpreadSheetAi.Sheets.Key.
      add :name_key, :text, null: false
      add :column_type, :string, null: false
      add :is_label, :boolean, null: false, default: false
      # 0-based; renumbered on insert, move or delete, so not unique.
      add :position, :integer, null: false
    end

    create unique_index(:sheet_columns, [:sheet_id, :name_key])

    create unique_index(:sheet_columns, [:sheet_id],
             where: "is_label",
             name: :sheet_columns_one_label_per_sheet_index
           )

    create constraint(:sheet_columns, :sheet_columns_column_type_check,
             check: "column_type IN ('text', 'number', 'boolean', 'date')"
           )

    # The label column is always text (contract §2.2).
    create constraint(:sheet_columns, :sheet_columns_label_is_text_check,
             check: "NOT is_label OR column_type = 'text'"
           )
  end
end
