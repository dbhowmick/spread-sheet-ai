defmodule SpreadSheetAi.Sheets.ConversationSheetQueries do
  @moduledoc "Composable queries for `SpreadSheetAi.Sheets.ConversationSheet`."

  import Ecto.Query

  alias SpreadSheetAi.Sheets.ConversationSheet

  def for_conversation(query \\ ConversationSheet, conversation_id) do
    where(query, [l], l.conversation_id == ^conversation_id)
  end

  def recent_first(query \\ ConversationSheet) do
    order_by(query, [l], desc: l.last_accessed_at, desc: l.id)
  end

  @doc """
  The `on_conflict` update for relinking an existing pair: take the new
  access, keep `first_accessed_at`, and OR `created_here`.
  """
  def relink do
    from(l in ConversationSheet,
      update: [
        set: [
          last_access: fragment("EXCLUDED.last_access"),
          last_accessed_at: fragment("EXCLUDED.last_accessed_at"),
          created_here: fragment("? OR EXCLUDED.created_here", l.created_here)
        ]
      ]
    )
  end
end
