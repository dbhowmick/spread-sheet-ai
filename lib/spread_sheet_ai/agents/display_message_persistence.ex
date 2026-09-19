defmodule SpreadSheetAi.Agents.DisplayMessagePersistence do
  @moduledoc """
  Implements `Sagents.DisplayMessagePersistence` for display messages.

  Persists user-facing message representations to PostgreSQL and handles
  tool execution lifecycle status updates. Called from within the AgentServer
  process for exactly-once semantics.

  A user message's sender (CS-3) travels in `message.metadata` as
  `"sender_user_id"` and `"sender_display_name"` (see
  `SpreadSheetAi.Agents.Chat`), and is copied into each saved row's
  `metadata`. The name is kept as it was when the message was sent.
  """

  @behaviour Sagents.DisplayMessagePersistence

  require Logger

  alias LangChain.Message
  alias Sagents.Message.DisplayHelpers

  @sender_keys ["sender_user_id", "sender_display_name"]

  @impl true
  def save_message(scope, %Message{} = message, context) do
    message
    |> DisplayHelpers.extract_display_items()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case save_item(scope, context, item_attrs(message, item, index)) do
        {:ok, display_msg} -> {:cont, {:ok, acc ++ [display_msg]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def update_tool_status(scope, :executing, %{call_id: call_id}, _context) do
    SpreadSheetAi.Conversations.mark_tool_executing(scope, call_id)
  end

  def update_tool_status(
        scope,
        :completed,
        %{call_id: call_id, result: result} = tool_info,
        _context
      ) do
    metadata = %{"result" => result}

    metadata =
      case Map.get(tool_info, :display_text) do
        nil -> metadata
        text -> Map.put(metadata, "display_text", text)
      end

    SpreadSheetAi.Conversations.complete_tool_call(scope, call_id, metadata)
  end

  def update_tool_status(scope, :failed, %{call_id: call_id, error: error}, _context) do
    SpreadSheetAi.Conversations.fail_tool_call(scope, call_id, %{"error" => error})
  end

  def update_tool_status(
        scope,
        :interrupted,
        %{call_id: call_id, display_text: display_text},
        _context
      ) do
    SpreadSheetAi.Conversations.interrupt_tool_call(scope, call_id, %{
      "display_text" => display_text
    })
  end

  def update_tool_status(scope, :cancelled, %{call_id: call_id}, _context) do
    SpreadSheetAi.Conversations.cancel_tool_call(scope, call_id)
  end

  @doc """
  Resolves an interrupted tool result display message with the actual result content.
  Called after a sub-agent resumes and completes.
  """
  @impl true
  def resolve_tool_result(scope, tool_call_id, result_content, _context) do
    SpreadSheetAi.Conversations.resolve_interrupted_tool_result(
      scope,
      tool_call_id,
      result_content
    )
  end

  @impl true
  def save_synthetic_message(_scope, _attrs, %{conversation_id: nil}),
    do: {:error, :no_conversation}

  def save_synthetic_message(scope, attrs, %{conversation_id: conversation_id}) do
    SpreadSheetAi.Conversations.append_display_message(scope, conversation_id, attrs)
  end

  defp sender_metadata(%Message{metadata: metadata}) when is_map(metadata),
    do: Map.take(metadata, @sender_keys)

  defp sender_metadata(%Message{}), do: %{}

  defp item_attrs(message, item, index) do
    # `sequence` is message-local. A message that yields several items
    # (thinking, then text, then tool calls) needs it to order them, since
    # they are all inserted within the same microsecond and share a timestamp.
    attrs = %{
      "message_type" => Atom.to_string(item.message_type),
      "content_type" => Atom.to_string(item.type),
      "content" => item.content,
      "sequence" => index,
      "metadata" => sender_metadata(message)
    }

    # Pull the tool-call id out of `content` into the top-level
    # `tool_call_id` column so the lifecycle queries can use an indexed
    # equality lookup. Tool calls additionally start in "pending" status.
    case item do
      %{type: :tool_call, content: %{"call_id" => call_id}} ->
        Map.merge(attrs, %{"tool_call_id" => call_id, "status" => "pending"})

      %{type: :tool_result, content: %{"tool_call_id" => tool_call_id}} ->
        Map.put(attrs, "tool_call_id", tool_call_id)

      _other ->
        attrs
    end
  end

  defp save_item(scope, context, attrs) do
    case SpreadSheetAi.Conversations.append_display_message(
           scope,
           context.conversation_id,
           attrs
         ) do
      {:ok, display_msg} ->
        {:ok, display_msg}

      {:error, reason} ->
        Logger.error(
          "Failed to persist DisplayMessage (#{attrs["content_type"]}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
