defmodule SpreadSheetAi.Repo.Migrations.CreateSheetRows do
  use Ecto.Migration

  def change do
    create table(:sheet_rows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sheet_id, references(:sheets, type: :binary_id, on_delete: :delete_all), null: false

      # The label column's value.
      add :label, :text, null: false
      # lower(trim(label)), computed in Elixir — see SpreadSheetAi.Sheets.Key.
      add :label_key, :text, null: false
      # 0-based; renumbered on insert, move or delete, so not unique.
      add :position, :integer, null: false
      # %{column_id => value} for non-label columns. Nulls are left out.
      add :values, :map, null: false, default: fragment("'{}'::jsonb")
    end

    create unique_index(:sheet_rows, [:sheet_id, :label_key])
  end
end
