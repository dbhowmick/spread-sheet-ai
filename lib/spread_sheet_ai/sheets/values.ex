defmodule SpreadSheetAi.Sheets.Values do
  @moduledoc """
  Cell values per column type (contract §2.2). Stored values are JSON-native
  so they round-trip through jsonb unchanged:

    * `text` — a string; `""` is stored as `nil` (an empty cell)
    * `number` — an integer or float within ±2^53; whole floats become
      integers (`12.0` → `12`)
    * `boolean` — `true` / `false`
    * `date` — a `"YYYY-MM-DD"` string

  `nil` is an empty cell in every type.
  """

  @type column_type :: String.t()
  @type value :: String.t() | number() | boolean() | nil

  # Largest integer a double represents exactly (contract: numbers are doubles).
  @max_number 9_007_199_254_740_992

  @date_format ~r/\A\d{4}-\d{2}-\d{2}\z/

  @doc "Casts a JSON value for a column of `type` into its stored form."
  @spec cast(column_type(), term()) :: {:ok, value()} | {:error, :invalid_value}
  def cast(_type, nil), do: {:ok, nil}
  def cast("text", ""), do: {:ok, nil}
  def cast("text", value) when is_binary(value), do: {:ok, value}

  def cast("number", value) when is_number(value) and abs(value) <= @max_number,
    do: {:ok, normalize_number(value)}

  def cast("boolean", value) when is_boolean(value), do: {:ok, value}
  def cast("date", value) when is_binary(value), do: cast_date(value)
  def cast(_type, _value), do: {:error, :invalid_value}

  @doc """
  Converts a stored value from one column type to another, for
  `change_column_type`. Returns `:error` when the value can't be converted.
  Blank text converts to `nil` in every type.
  """
  @spec convert(column_type(), column_type(), value()) :: {:ok, value()} | :error
  def convert(_from, _to, nil), do: {:ok, nil}
  def convert(type, type, value), do: {:ok, value}
  def convert(_from, "text", value), do: {:ok, to_text(value)}

  def convert("text", to, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> from_text(to, trimmed)
    end
  end

  def convert("boolean", "number", true), do: {:ok, 1}
  def convert("boolean", "number", false), do: {:ok, 0}
  def convert("number", "boolean", 1), do: {:ok, true}
  def convert("number", "boolean", 0), do: {:ok, false}
  def convert(_from, _to, _value), do: :error

  defp from_text("number", text) do
    case parse_number(text) do
      {:ok, number} -> ok_or_error(cast("number", number))
      :error -> :error
    end
  end

  defp from_text("date", text), do: ok_or_error(cast_date(text))

  defp from_text("boolean", text) do
    case String.downcase(text) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  defp parse_number(text) do
    case Integer.parse(text) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(text) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp cast_date(value) do
    with true <- Regex.match?(@date_format, value),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, Date.to_iso8601(date)}
    else
      _ -> {:error, :invalid_value}
    end
  end

  defp ok_or_error({:ok, value}), do: {:ok, value}
  defp ok_or_error({:error, _}), do: :error

  defp normalize_number(value) when is_integer(value), do: value

  defp normalize_number(value) when is_float(value) do
    if value == Float.floor(value), do: trunc(value), else: value
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_text(value) when is_float(value), do: Float.to_string(value)
  defp to_text(true), do: "true"
  defp to_text(false), do: "false"
end
