defmodule SpreadSheetAi.Agents.TruncationAwareChat do
  @moduledoc """
  A streaming `ChatReqLLM` that reports a reply cut off by `max_tokens` as
  cut off.

  `ChatReqLLM` (langchain 0.14.3) takes a streamed turn's finish reason
  from the stream's terminal chunk only. Over OpenRouter that chunk is
  `[DONE]`, which req_llm (1.25.0) decodes with no finish reason, so a reply
  that hit the limit ends with status `:complete` instead of `:length`.
  The agent then treats it as finished: a half-written tool call is
  dropped, the turn ends on whatever thinking streamed, and nothing tells
  the user. A non-streamed call reports `:length` correctly.

  This model delegates to `ChatReqLLM` and fixes the streamed status. A
  turn whose output tokens reached `max_tokens` was cut off: its terminal
  delta becomes `:length`, which Sagents ends the run on (as a
  `"response_truncated"` error) and marks in the transcript
  (`"stop_reason" => "length"`).

  LLMChain calls `module.call/3` on the struct it holds and puts its
  callbacks in `:callbacks`, so the struct carries those and hands them to
  the wrapped model on each call.
  """

  @behaviour LangChain.ChatModels.ChatModel

  alias LangChain.ChatModels.ChatModel
  alias LangChain.ChatModels.ChatReqLLM
  alias LangChain.MessageDelta

  defstruct [:model, callbacks: []]

  @type t :: %__MODULE__{model: ChatReqLLM.t(), callbacks: [map()]}

  @doc "Builds the wrapped `ChatReqLLM` from `attrs` (see `ChatReqLLM.new!/1`)."
  @spec new!(map()) :: t()
  def new!(attrs), do: %__MODULE__{model: ChatReqLLM.new!(attrs)}

  @impl ChatModel
  def call(%__MODULE__{model: model, callbacks: callbacks}, messages, functions) do
    model = %{model | callbacks: model.callbacks ++ callbacks}

    case ChatReqLLM.call(model, messages, functions) do
      {:ok, [%MessageDelta{} | _] = deltas} when model.stream ->
        {:ok, mark_cut_off(deltas, model.max_tokens)}

      result ->
        result
    end
  end

  @doc """
  Marks a streamed turn as cut off when its output reached `max_tokens`.

  Only a terminal delta reporting `:complete` changes; one that already
  names another status (`:length`, `:content_filtered`) is right as it is.
  """
  @spec mark_cut_off([MessageDelta.t() | term()], pos_integer() | nil) :: [
          MessageDelta.t() | term()
        ]
  def mark_cut_off(deltas, max_tokens) when is_integer(max_tokens) do
    if output_tokens(deltas) >= max_tokens do
      Enum.map(deltas, fn
        %MessageDelta{status: :complete} = delta -> %{delta | status: :length}
        other -> other
      end)
    else
      deltas
    end
  end

  def mark_cut_off(deltas, _max_tokens), do: deltas

  defp output_tokens(deltas) do
    case ChatModel.token_usage_from_result({:ok, deltas}) do
      %{token_usage: %{output: output}} when is_integer(output) -> output
      _no_usage -> 0
    end
  end

  @impl ChatModel
  def retry_on_fallback?(error), do: ChatReqLLM.retry_on_fallback?(error)

  @impl ChatModel
  def serialize_config(%__MODULE__{model: model}), do: ChatReqLLM.serialize_config(model)

  @impl ChatModel
  def restore_from_map(data) do
    with {:ok, model} <- ChatReqLLM.restore_from_map(data) do
      {:ok, %__MODULE__{model: model}}
    end
  end
end
