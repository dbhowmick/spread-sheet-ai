defmodule SpreadSheetAi.Agents.ChatModels do
  @moduledoc """
  Builds the copilot's chat models from `config :spread_sheet_ai, :ai`
  (docs/backend-plan.md §7.4).

  By default both are `ChatReqLLM` models for OpenRouter model ids
  (`"openrouter:<vendor>/<model>"`); ReqLLM reads `OPENROUTER_API_KEY`
  itself. Setting `chat_model_builder: Module` makes `main/0` and `title/0`
  delegate to that module instead, which is how tests swap in
  `SpreadSheetAi.Test.ScriptedChatModel`.
  """

  alias LangChain.ChatModels.ChatReqLLM

  @doc "The model that runs the conversation. Streams."
  @callback main() :: struct()

  @doc "The cheaper model that writes conversation titles. Doesn't stream."
  @callback title() :: struct()

  @spec main() :: struct()
  def main do
    case builder() do
      nil -> ChatReqLLM.new!(%{model: config!(:model), stream: true, max_tokens: max_tokens()})
      builder -> builder.main()
    end
  end

  @spec title() :: struct()
  def title do
    case builder() do
      nil -> ChatReqLLM.new!(%{model: config!(:title_model), stream: false})
      builder -> builder.title()
    end
  end

  defp builder, do: Keyword.get(config(), :chat_model_builder)

  defp max_tokens, do: Keyword.get(config(), :max_tokens)

  defp config!(key), do: Keyword.fetch!(config(), key)

  defp config, do: Application.get_env(:spread_sheet_ai, :ai, [])
end
