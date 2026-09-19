defmodule SpreadSheetAi.Repo.Migrations.CreateConversationSheets do
  use Ecto.Migration

  def change do
    # Which sheets each conversation has used (ST-1).
    create table(:conversation_sheets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:sagents_conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sheet_id, references(:sheets, type: :binary_id, on_delete: :delete_all), null: false

      # Whether the sheet was created in this conversation.
      add :created_here, :boolean, null: false, default: false
      # How the conversation last used the sheet.
      add :last_access, :string, null: false
      add :first_accessed_at, :utc_datetime, null: false
      add :last_accessed_at, :utc_datetime, null: false
    end

    create unique_index(:conversation_sheets, [:conversation_id, :sheet_id])
    create index(:conversation_sheets, [:sheet_id])

    create constraint(:conversation_sheets, :conversation_sheets_last_access_check,
             check: "last_access IN ('created', 'opened', 'read', 'written')"
           )
  end
end
