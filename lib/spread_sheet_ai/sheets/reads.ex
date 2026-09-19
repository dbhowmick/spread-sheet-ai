defmodule SpreadSheetAi.Sheets.Reads do
  @moduledoc """
  Pure reads over a `SpreadSheetAi.Sheets.State`, served by the sheet server
  from memory. Rows are referred to by label and columns by name (both
  trimmed and case-insensitive on input), as the AI tools do (backend-plan
  §8.2); results use the stored labels and names.

  `max` is the `read_max_rows` cap. Errors are
  `{:error, code, message, meta}`, as in the engine.
  """

  alias SpreadSheetAi.Sheets.{Key, State}

  @type error :: {:error, atom(), String.t(), map()}

  @doc "The sheet's structure: columns, row count and version. No values."
  @spec describe(State.t()) :: map()
  def describe(%State{} = state) do
    %{
      id: state.id,
      name: state.name,
      version: state.version,
      columns:
        Enum.map(
          State.columns(state),
          &%{name: &1.name, column_type: &1.column_type, is_label: &1.is_label}
        ),
      row_count: length(state.row_order)
    }
  end

  @doc """
  A page of rows as `%{label, values: %{column_name => value}}`, where
  `values` holds every non-label column (empty cells as `nil`), or only
  those named in `:columns`. Options: `:offset` (default 0), `:limit`
  (default and at most `max`), `:columns`.
  """
  @spec read_rows(State.t(), keyword(), pos_integer()) :: {:ok, map()} | error()
  def read_rows(%State{} = state, opts, max) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, max)

    with :ok <- check_offset(offset),
         :ok <- check_limit(limit),
         {:ok, columns} <- value_columns(state, Keyword.get(opts, :columns)) do
      rows =
        state
        |> State.rows()
        |> Enum.slice(offset, min(limit, max))
        |> Enum.map(&%{label: &1.label, values: values(&1.values, columns)})

      {:ok, %{rows: rows, total: length(state.row_order), offset: offset}}
    end
  end

  @doc """
  The cells at `labels` × `column_names`, as
  `%{label => %{column_name => value}}`. Naming the label column returns
  the label. More than `max` labels is `too_many_cells`.
  """
  @spec read_cells(State.t(), [String.t()], [String.t()], pos_integer()) ::
          {:ok, map()} | error()
  def read_cells(%State{} = state, labels, column_names, max) do
    with :ok <- check_cap(length(labels), max),
         {:ok, rows} <- fetch_all(labels, &fetch_row(state, &1)),
         {:ok, columns} <- fetch_all(column_names, &fetch_column(state, &1)) do
      {:ok,
       Map.new(rows, fn row ->
         cells = State.row_cells(state, row)
         {row.label, Map.new(columns, &{&1.name, Map.get(cells, &1.id)})}
       end)}
    end
  end

  @doc """
  Labels containing `query` (trimmed, case-insensitive), in row order, at
  most `max` of them. `truncated` says whether more rows matched.
  """
  @spec find_rows(State.t(), String.t(), pos_integer()) :: map()
  def find_rows(%State{} = state, query, max) when is_binary(query) do
    needle = Key.normalize(query)

    matches =
      state
      |> State.rows()
      |> Stream.filter(&String.contains?(Key.normalize(&1.label), needle))
      |> Enum.take(max + 1)

    %{rows: matches |> Enum.take(max) |> Enum.map(& &1.label), truncated: length(matches) > max}
  end

  defp value_columns(state, nil),
    do: {:ok, state |> State.columns() |> Enum.reject(& &1.is_label)}

  defp value_columns(state, names) do
    with {:ok, columns} <- fetch_all(names, &fetch_column(state, &1)),
         do: {:ok, Enum.reject(columns, & &1.is_label)}
  end

  defp values(values, columns), do: Map.new(columns, &{&1.name, Map.get(values, &1.id)})

  defp fetch_all(names, fetch) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case fetch.(name) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc "Finds a column by name (trimmed, case-insensitive), or `unknown_column`."
  @spec fetch_column(State.t(), String.t()) :: {:ok, State.column()} | error()
  def fetch_column(%State{} = state, name) do
    case State.fetch_column_by_name(state, name) do
      {:ok, column} ->
        {:ok, column}

      :error ->
        {:error, :unknown_column, "column \"#{name}\" does not exist in sheet \"#{state.name}\"",
         %{column: name}}
    end
  end

  @doc "Finds a row by label (trimmed, case-insensitive), or `unknown_row`."
  @spec fetch_row(State.t(), String.t()) :: {:ok, State.row()} | error()
  def fetch_row(%State{} = state, label) do
    case State.fetch_row_by_label(state, label) do
      {:ok, row} ->
        {:ok, row}

      :error ->
        {:error, :unknown_row, "row \"#{label}\" does not exist in sheet \"#{state.name}\"",
         %{label: label}}
    end
  end

  defp check_offset(offset) when is_integer(offset) and offset >= 0, do: :ok

  defp check_offset(offset),
    do:
      {:error, :invalid_position, "offset must be a non-negative integer, got #{inspect(offset)}",
       %{}}

  defp check_limit(limit) when is_integer(limit) and limit > 0, do: :ok

  defp check_limit(limit),
    do: {:error, :invalid_op, "limit must be a positive integer, got #{inspect(limit)}", %{}}

  defp check_cap(count, max) when count <= max, do: :ok

  defp check_cap(_count, max),
    do: {:error, :too_many_cells, "at most #{max} rows can be read at once", %{max: max}}
end
