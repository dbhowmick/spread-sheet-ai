defmodule SpreadSheetAi.Repo.Migrations.CreateSheets do
  use Ecto.Migration

  def change do
    create table(:sheets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false

      add :owner_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      # Goes up by one for every applied op.
      add :version, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:sheets, [:owner_id])
  end
end
