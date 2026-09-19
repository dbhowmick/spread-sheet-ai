defmodule SpreadSheetAi.Repo.Migrations.CreateSheetChanges do
  use Ecto.Migration

  def change do
    create table(:sheet_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sheet_id, references(:sheets, type: :binary_id, on_delete: :delete_all), null: false

      # The sheet version this op produced.
      add :version, :integer, null: false
      # The normalized AppliedOp (contract §6).
      add :op, :map, null: false
      add :actor_type, :string, null: false

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # No FK: sagents_conversations is created in Phase 6.
      add :conversation_id, :binary_id
      add :client_op_id, :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:sheet_changes, [:sheet_id, :version])

    create constraint(:sheet_changes, :sheet_changes_actor_type_check,
             check: "actor_type IN ('user', 'agent')"
           )
  end
end
