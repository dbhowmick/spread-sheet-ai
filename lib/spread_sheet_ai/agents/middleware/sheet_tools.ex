defmodule SpreadSheetAi.Agents.Middleware.SheetTools do
  @moduledoc """
  Gives the copilot its sheet tools and tells it which sheets the
  conversation uses (backend-plan §8.1).

  - `tools/1`: the 16 tools in `SpreadSheetAi.Agents.Tools.*`.
  - `before_model/2`: before each run, puts a `<linked_sheets>` block at the
    start of the latest user message (AI-1). It lists each linked sheet's id,
    name, columns with their types, and row count, but no values.

  The block goes into a user message because Sagents builds the system
  message itself, once per agent: a second system message fails the run.
  `before_model/2` runs once per run, not before every model call in the
  tool loop, so tools return the structures they change. Older blocks stay
  in the history, and `Summarization` keeps long sessions in bounds.
  """

  @behaviour Sagents.Middleware

  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias Sagents.State
  alias SpreadSheetAi.Agents.Tools.{Cells, Read, Rows, Structure}
  alias SpreadSheetAi.Sheets

  @impl Sagents.Middleware
  def tools(_config),
    do: Read.functions() ++ Structure.functions() ++ Rows.functions() ++ Cells.functions()

  @impl Sagents.Middleware
  def before_model(%State{} = state, _config) do
    case last_user_index(state.messages) do
      nil ->
        {:ok, state}

      index ->
        block = ContentPart.text!(linked_sheets(state.conversation_id))
        messages = List.update_at(state.messages, index, &prepend(&1, block))
        {:ok, %{state | messages: messages}}
    end
  end

  @doc "The `<linked_sheets>` block for a conversation."
  @spec linked_sheets(String.t() | nil) :: String.t()
  def linked_sheets(conversation_id) do
    lines =
      case conversation_id && Sheets.list_links(conversation_id) do
        links when is_list(links) and links != [] -> Enum.map(links, &describe_link/1)
        _none -> ["No sheets are linked to this conversation yet. Use list_sheets to find one."]
      end

    Enum.join(["<linked_sheets>" | lines] ++ ["</linked_sheets>"], "\n")
  end

  defp describe_link(%{sheet: %{id: id} = summary}) do
    columns =
      case Sheets.describe(id) do
        {:ok, %{columns: columns}} -> Enum.map_join(columns, ", ", &describe_column/1)
        _error -> "(unavailable)"
      end

    "- \"#{summary.name}\" (id: #{id}), #{summary.row_count} rows. Columns: #{columns}"
  end

  defp describe_column(%{is_label: true} = column),
    do: "#{column.name} (#{column.column_type}, line item)"

  defp describe_column(column), do: "#{column.name} (#{column.column_type})"

  defp last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :user}, index} -> index
      _other -> nil
    end)
  end

  defp prepend(%Message{content: parts} = message, block) when is_list(parts),
    do: %{message | content: [block | parts]}

  defp prepend(%Message{content: text} = message, block) when is_binary(text),
    do: %{message | content: [block, ContentPart.text!(text)]}

  defp prepend(%Message{} = message, block), do: %{message | content: [block]}
end
