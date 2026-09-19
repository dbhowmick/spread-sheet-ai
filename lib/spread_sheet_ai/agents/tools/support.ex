defmodule SpreadSheetAi.Agents.Tools.Support do
  @moduledoc """
  Shared plumbing for the copilot's sheet tools (backend-plan §8.2).

  - **Arguments.** LangChain only checks that required keys are present, so
    each tool checks its arguments' types itself (`fetch_*`) before calling
    `SpreadSheetAi.Sheets`. A bad argument becomes an `ERROR
    invalid_arguments: …` result the model can fix.
  - **Errors.** ChatReqLLM sends the model a tool result's text but not its
    error flag, so `error/2` writes text that says it is an error and how to
    fix it (AI-4).
  - **Links and focus.** `touch/3` links the sheet to the conversation
    (ST-1) and tells the conversation's viewers (UI-4), before the tool
    returns.
  - **Actor.** Writes are made as the conversation (AI-6), with its title.

  Tool functions take `(args, context)`, where `context` is the Sagents
  tool context: it carries `:conversation_id` and `:scope`.
  """

  require Logger

  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Conversations
  alias SpreadSheetAi.Conversations.Conversation
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{Actor, Column}

  @type result :: {:ok, String.t()} | {:error, String.t()}

  # ----- Argument schemas -----

  @doc "A strict object schema: every listed key is known, `required` must be present."
  @spec object(map(), [String.t()]) :: map()
  def object(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  @doc "The `sheet_id` property."
  @spec sheet_id_schema() :: map()
  def sheet_id_schema,
    do: %{"type" => "string", "description" => "The sheet's id (a UUID)."}

  @doc "A column type property."
  @spec type_schema(String.t()) :: map()
  def type_schema(description),
    do: %{"type" => "string", "enum" => Column.types(), "description" => description}

  @doc "A cell value: a literal of the column's type, or null to clear the cell."
  @spec value_schema() :: map()
  def value_schema do
    %{
      "type" => ["string", "number", "boolean", "null"],
      "description" =>
        "A literal value: text, a number, true/false, or a date as YYYY-MM-DD. null clears the cell."
    }
  end

  @doc "A map from column name to value."
  @spec values_schema() :: map()
  def values_schema do
    %{
      "type" => "object",
      "description" => "Cell values keyed by column name. Leave out the line-item column.",
      "additionalProperties" => value_schema()
    }
  end

  @doc "A 0-based position property."
  @spec position_schema(String.t()) :: map()
  def position_schema(description),
    do: %{"type" => "integer", "minimum" => 0, "description" => description}

  # ----- Argument checks -----

  @doc "A required string argument."
  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> invalid_arguments(~s("#{key}" is required))
      _ -> invalid_arguments(~s("#{key}" must be a string))
    end
  end

  @doc "A required column type argument."
  @spec fetch_type(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_type(args, key) do
    with {:ok, type} <- fetch_string(args, key) do
      if type in Column.types(),
        do: {:ok, type},
        else: invalid_arguments(~s("#{key}" must be one of #{Enum.join(Column.types(), ", ")}))
    end
  end

  @doc "An integer argument of at least `min`; `nil` when optional and missing."
  @spec fetch_integer(map(), String.t(), integer(), :required | :optional) ::
          {:ok, integer() | nil} | {:error, String.t()}
  def fetch_integer(args, key, min, required \\ :optional) do
    case Map.get(args, key) do
      nil when required == :optional -> {:ok, nil}
      nil -> invalid_arguments(~s("#{key}" is required))
      value when is_integer(value) and value >= min -> {:ok, value}
      _ -> invalid_arguments(~s("#{key}" must be an integer of at least #{min}))
    end
  end

  @doc "A non-empty list of strings; `nil` when optional and missing."
  @spec fetch_strings(map(), String.t(), :required | :optional) ::
          {:ok, [String.t()] | nil} | {:error, String.t()}
  def fetch_strings(args, key, required \\ :required) do
    case Map.get(args, key) do
      nil when required == :optional ->
        {:ok, nil}

      [_ | _] = list ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: invalid_arguments(~s("#{key}" must be a list of strings))

      _ ->
        invalid_arguments(~s("#{key}" must be a non-empty list of strings))
    end
  end

  @doc "A non-empty list of objects; `nil` when optional and missing."
  @spec fetch_objects(map(), String.t(), :required | :optional) ::
          {:ok, [map()] | nil} | {:error, String.t()}
  def fetch_objects(args, key, required \\ :required) do
    case Map.get(args, key) do
      nil when required == :optional ->
        {:ok, nil}

      [_ | _] = list ->
        if Enum.all?(list, &is_map/1),
          do: {:ok, list},
          else: invalid_arguments(~s("#{key}" must be a list of objects))

      _ ->
        invalid_arguments(~s("#{key}" must be a non-empty list of objects))
    end
  end

  defp invalid_arguments(message),
    do:
      {:error, "ERROR invalid_arguments: #{message}. Fix the arguments and call the tool again."}

  # ----- Results -----

  @doc "A successful result as JSON text."
  @spec json(term()) :: {:ok, String.t()}
  def json(result), do: {:ok, Jason.encode!(result)}

  @doc """
  An error from `SpreadSheetAi.Sheets` as text the model can act on:
  `ERROR <code>: <message>`, then a hint on how to fix it.
  """
  @spec error(Sheets.error(), String.t() | nil) :: {:error, String.t()}
  def error({:error, code, message, meta}, sheet_id) do
    # `validation_failed` messages ("can't be blank") don't name their field.
    message =
      case {code, meta} do
        {:validation_failed, %{field: field}} -> ~s("#{field}" #{message})
        _other -> message
      end

    text =
      ["ERROR #{code}: #{message}.", hint(code, sheet_id)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {:error, text}
  end

  defp hint(:unknown_column, sheet_id) when is_binary(sheet_id) do
    case Sheets.describe(sheet_id) do
      {:ok, %{columns: columns}} ->
        "Existing columns: #{Enum.map_join(columns, ", ", & &1.name)}."

      _error ->
        nil
    end
  end

  defp hint(:unknown_row, _sheet_id),
    do: "Use find_rows or read_rows to look up the exact row labels."

  defp hint(:not_found, _sheet_id), do: "Use list_sheets to find sheet ids."

  defp hint(:internal_error, _sheet_id),
    do: "The change was not made. This is not caused by your arguments; try again."

  defp hint(_code, _sheet_id), do: "Fix the arguments and call the tool again."

  # ----- Conversation -----

  @doc """
  Records that the conversation used a sheet (`kind`: `:created`,
  `:opened`, `:read` or `:written`), then tells its viewers to focus the
  sheet and reload the linked sheets. Called only after the tool succeeded,
  and before it returns, so `focus_sheet` comes before the tool's result
  (contract §7.3).
  """
  @spec touch(map(), String.t(), Sheets.access_kind()) :: :ok
  def touch(context, sheet_id, kind) do
    conversation_id = context.conversation_id

    case Sheets.link(conversation_id, sheet_id, kind) do
      {:ok, _link} ->
        Conversations.broadcast_event(conversation_id, {:focus_sheet, sheet_id, kind})
        Conversations.broadcast_event(conversation_id, {:sheets_changed})

      {:error, code, message, _meta} ->
        Logger.warning(
          "conversation #{conversation_id}: linking sheet #{sheet_id} failed: #{code} #{message}"
        )
    end

    :ok
  end

  @doc "The tool's conversation, with its creator preloaded."
  @spec conversation(map()) :: {:ok, Conversation.t()} | {:error, String.t()}
  def conversation(context) do
    case Conversations.get_conversation(scope(context), context.conversation_id) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :not_found} -> {:error, "ERROR not_found: this conversation no longer exists."}
    end
  end

  @doc "The actor for the conversation's changes (AI-6)."
  @spec actor(Conversation.t()) :: Actor.t()
  def actor(%Conversation{} = conversation), do: Actor.agent(conversation.id, conversation.title)

  defp scope(%{scope: %Scope{} = scope}), do: scope
  defp scope(_context), do: %Scope{}

  @doc """
  Applies a name-based op (`SpreadSheetAi.Sheets.Named`) as the
  conversation, links the sheet as `:written`, and returns
  `result.(version, applied_op)` as JSON.
  """
  @spec write(map(), String.t(), map(), (pos_integer(), map() -> map())) :: result()
  def write(context, sheet_id, named_op, result) do
    with {:ok, conversation} <- conversation(context) do
      case Sheets.apply_named(sheet_id, named_op, actor(conversation)) do
        {:ok, version, applied_op} ->
          touch(context, sheet_id, :written)
          json(result.(version, applied_op))

        error ->
          error(error, sheet_id)
      end
    end
  end

  @doc "Just the new version, for writes with nothing else to report."
  @spec version(pos_integer(), map()) :: map()
  def version(version, _applied_op), do: %{version: version}
end
