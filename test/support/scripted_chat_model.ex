defmodule SpreadSheetAi.Test.ScriptedChatModel do
  @moduledoc """
  A chat model for tests that replies from a script instead of calling an
  LLM (docs/backend-plan.md §11). Test config makes
  `SpreadSheetAi.Agents.ChatModels` build it (`chat_model_builder`).

  Start the script store in the test with `start_supervised!(ScriptedChatModel)`.
  It is a named process, so tests that use it must be `async: false`, as
  agent tests are anyway.

  There are two queues, so the title task, which runs alongside the agent's
  first call, never takes the agent's replies:

  - `:main`: the conversation model (`main/0`, streams). An empty queue
    fails the call with an error that says so.
  - `:title`: the title model (`title/0`, doesn't stream). An empty queue
    replies `"Scripted title"`.

  Each scripted response is one of:

  - `"text"`: an assistant reply. Streamed as a few deltas on `:main`.
  - `{:tool_calls, [%{name: name, arguments: map}]}`: an assistant message
    calling tools.
  - `{:error, message}`: the call fails.
  - `fn messages, tools -> response end`: decides at call time.

  `calls/1` returns the `{messages, tools}` each call received, oldest first.
  """

  @behaviour LangChain.ChatModels.ChatModel

  use Agent

  alias LangChain.Callbacks
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.MessageDelta
  alias LangChain.Utils

  @default_title "Scripted title"

  defstruct queue: :main, stream: true, callbacks: []

  @type t :: %__MODULE__{queue: :main | :title, stream: boolean(), callbacks: [map()]}

  def start_link(_opts) do
    Agent.start_link(fn -> %{responses: %{}, calls: %{}} end, name: __MODULE__)
  end

  @doc "The conversation model. See `SpreadSheetAi.Agents.ChatModels`."
  def main, do: %__MODULE__{queue: :main, stream: true}

  @doc "The title model. See `SpreadSheetAi.Agents.ChatModels`."
  def title, do: %__MODULE__{queue: :title, stream: false}

  @doc "Appends responses to a queue."
  def push(queue \\ :main, responses) when is_list(responses) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:responses, Access.key(queue, [])], &(&1 ++ responses))
    end)
  end

  @doc "The `{messages, tools}` of every call made on a queue, oldest first."
  def calls(queue \\ :main) do
    Agent.get(__MODULE__, &Map.get(&1.calls, queue, []))
  end

  @impl LangChain.ChatModels.ChatModel
  def call(%__MODULE__{} = model, messages, tools) do
    messages = List.wrap(messages)

    case next_response(model.queue, messages, tools) do
      :empty when model.queue == :title -> respond(model, @default_title)
      :empty -> error("the #{inspect(model.queue)} script has no response left")
      response -> respond(model, resolve(response, messages, tools))
    end
  end

  @impl LangChain.ChatModels.ChatModel
  def retry_on_fallback?(_error), do: false

  @impl LangChain.ChatModels.ChatModel
  def serialize_config(%__MODULE__{} = model) do
    %{"module" => inspect(__MODULE__), "queue" => Atom.to_string(model.queue)}
  end

  @impl LangChain.ChatModels.ChatModel
  def restore_from_map(%{"queue" => "title"}), do: {:ok, title()}
  def restore_from_map(_data), do: {:ok, main()}

  defp next_response(queue, messages, tools) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = update_in(state, [:calls, Access.key(queue, [])], &(&1 ++ [{messages, tools}]))

      case Map.get(state.responses, queue, []) do
        [] -> {:empty, state}
        [response | rest] -> {response, put_in(state, [:responses, queue], rest)}
      end
    end)
  end

  defp resolve(fun, messages, tools) when is_function(fun, 2),
    do: resolve(fun.(messages, tools), messages, tools)

  defp resolve(response, _messages, _tools), do: response

  defp respond(%__MODULE__{stream: true} = model, text) when is_binary(text) do
    deltas = text_deltas(text)
    Utils.fire_streamed_callback(model, deltas)
    {:ok, deltas}
  end

  defp respond(%__MODULE__{} = model, text) when is_binary(text) do
    message = Message.new_assistant!(text)
    Callbacks.fire(model.callbacks, :on_llm_new_message, [message])
    {:ok, [message]}
  end

  defp respond(%__MODULE__{} = model, {:tool_calls, calls}) do
    tool_calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {%{name: name, arguments: arguments}, index} ->
        ToolCall.new!(%{
          call_id: "call_#{System.unique_integer([:positive])}",
          name: name,
          arguments: arguments,
          index: index,
          status: :complete
        })
      end)

    message = Message.new_assistant!(%{tool_calls: tool_calls})
    Callbacks.fire(model.callbacks, :on_llm_new_message, [message])
    {:ok, [message]}
  end

  defp respond(_model, {:error, message}), do: error(message)

  # Splits the text into a few streamed chunks; the last delta completes it.
  defp text_deltas(text) do
    size = max(div(String.length(text), 3), 1)

    chunks =
      text
      |> String.graphemes()
      |> Enum.chunk_every(size)
      |> Enum.map(&Enum.join/1)

    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      MessageDelta.new!(%{
        role: :assistant,
        content: chunk,
        index: 0,
        status: if(index == last, do: :complete, else: :incomplete)
      })
    end)
  end

  defp error(message), do: {:error, LangChainError.exception(message: message)}
end
