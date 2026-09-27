defmodule SpreadSheetAi.Agents.TruncationAwareChatTest do
  use ExUnit.Case, async: true

  alias LangChain.ChatModels.ChatReqLLM
  alias LangChain.Message.ContentPart
  alias LangChain.MessageDelta
  alias LangChain.TokenUsage
  alias SpreadSheetAi.Agents.TruncationAwareChat

  # A streamed turn the way ChatReqLLM returns it over OpenRouter: text
  # deltas, a usage delta, then a terminal delta from `[DONE]` that says
  # `:complete` whatever the finish reason was.
  defp streamed_turn(output_tokens) do
    [
      MessageDelta.new!(%{role: :assistant, content: ContentPart.text!("Half an"), index: 0}),
      MessageDelta.new!(%{
        role: :assistant,
        metadata: %{usage: TokenUsage.new!(%{input: 20, output: output_tokens})}
      }),
      MessageDelta.new!(%{role: :assistant, status: :complete, index: 0})
    ]
  end

  defp status(deltas) do
    {:ok, message} = deltas |> MessageDelta.merge_deltas() |> MessageDelta.to_message()
    message.status
  end

  describe "mark_cut_off/2" do
    test "a turn whose output reached max_tokens ends as :length" do
      assert streamed_turn(200) |> TruncationAwareChat.mark_cut_off(200) |> status() == :length
    end

    test "a turn under max_tokens stays :complete" do
      assert streamed_turn(199) |> TruncationAwareChat.mark_cut_off(200) |> status() == :complete
    end

    test "a turn with no usage is left alone" do
      deltas = List.delete_at(streamed_turn(200), 1)
      assert TruncationAwareChat.mark_cut_off(deltas, 200) == deltas
    end

    test "a status other than :complete is kept" do
      deltas =
        List.replace_at(
          streamed_turn(200),
          2,
          MessageDelta.new!(%{role: :assistant, status: :content_filtered, index: 0})
        )

      assert deltas |> TruncationAwareChat.mark_cut_off(200) |> status() == :content_filtered
    end

    test "without max_tokens nothing changes" do
      deltas = streamed_turn(200)
      assert TruncationAwareChat.mark_cut_off(deltas, nil) == deltas
    end
  end

  test "serializes and restores as the wrapped ChatReqLLM" do
    model = TruncationAwareChat.new!(%{model: "openrouter:x/y", stream: true, max_tokens: 100})
    config = TruncationAwareChat.serialize_config(model)

    assert {:ok,
            %TruncationAwareChat{model: %ChatReqLLM{model: "openrouter:x/y", max_tokens: 100}}} =
             TruncationAwareChat.restore_from_map(config)
  end
end
