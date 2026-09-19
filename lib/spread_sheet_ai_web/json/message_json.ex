defmodule SpreadSheetAiWeb.MessageJSON do
  @moduledoc """
  The contract `Message` (§2.10), from a stored
  `SpreadSheetAi.Conversations.DisplayMessage`. Pure: shared by the
  conversation channel's join reply and its pushes.
  """

  alias SpreadSheetAi.Conversations.DisplayMessage

  # The `content` keys each content type has in the contract. `stop_reason`
  # may be on any of them (the last item of a message that didn't finish).
  @content_keys %{
    "text" => ["text"],
    "thinking" => ["text"],
    "tool_call" => ["call_id", "name", "display_text", "arguments"],
    "tool_result" => ["tool_call_id", "name", "content", "is_error"],
    "notification" => ["text"],
    "error" => ["text", "error_type"]
  }

  @doc "A `Message`."
  @spec message(DisplayMessage.t()) :: map()
  def message(%DisplayMessage{} = message) do
    %{
      id: message.id,
      role: role(message.message_type),
      content_type: message.content_type,
      content: content(message.content_type, message.content || %{}),
      sender: sender(message),
      status: status(message.status),
      inserted_at: message.inserted_at
    }
  end

  # Rows Sagents writes itself (a cancel notice, a failed turn) are
  # `"system"`, which the contract doesn't have; they read as the AI's.
  defp role("system"), do: "assistant"
  defp role(role), do: role

  defp content(type, content) do
    case Map.fetch(@content_keys, type) do
      {:ok, keys} -> content |> Map.take(["stop_reason" | keys]) |> put_defaults(type)
      :error -> content
    end
  end

  defp put_defaults(content, "tool_call") do
    content
    |> Map.put_new("display_text", content["name"])
    |> Map.put_new("arguments", %{})
  end

  defp put_defaults(content, "tool_result"), do: Map.put_new(content, "is_error", false)
  defp put_defaults(content, "error"), do: Map.put_new(content, "error_type", nil)
  defp put_defaults(content, _type), do: content

  defp sender(%DisplayMessage{message_type: "user", metadata: %{"sender_user_id" => id} = meta}),
    do: %{id: id, display_name: meta["sender_display_name"]}

  defp sender(%DisplayMessage{}), do: nil

  # Tool calls are only interrupted by human-in-the-loop, which is off.
  defp status("interrupted"), do: "pending"
  defp status(nil), do: "completed"
  defp status(status), do: status
end
