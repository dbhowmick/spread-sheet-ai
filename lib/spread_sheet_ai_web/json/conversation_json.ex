defmodule SpreadSheetAiWeb.ConversationJSON do
  @moduledoc """
  Contract serializers for conversations (contract §2.8, §2.9 and §7).
  Pure: shared by `SpreadSheetAiWeb.Api.ConversationController` and
  `SpreadSheetAiWeb.ConversationChannel`.
  """

  alias SpreadSheetAi.Conversations.Conversation
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAiWeb.SheetJSON

  @doc "A `ConversationSummary` (§2.8). The creator (`user`) must be loaded."
  @spec summary(Conversation.t()) :: map()
  def summary(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      title: conversation.title,
      created_by: SheetJSON.user_ref(conversation.user),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  @doc "A `LinkedSheet` (§2.9), from `SpreadSheetAi.Sheets.list_links/1`."
  @spec linked_sheet(Sheets.linked_sheet()) :: map()
  def linked_sheet(link) do
    %{
      sheet: SheetJSON.summary(link.sheet),
      created_here: link.created_here,
      last_access: link.last_access,
      first_accessed_at: link.first_accessed_at,
      last_accessed_at: link.last_accessed_at
    }
  end

  @doc "The `sheets` push (§7.3): every linked sheet."
  @spec sheets([Sheets.linked_sheet()]) :: map()
  def sheets(links), do: %{sheets: Enum.map(links, &linked_sheet/1)}
end
