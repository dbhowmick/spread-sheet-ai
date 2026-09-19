defmodule SpreadSheetAi.Agents.Tools.Read do
  @moduledoc """
  The copilot's read tools (AI-2, AI-5): `list_sheets`, `open_sheet`,
  `read_rows`, `read_cells` and `find_rows`. Every tool except
  `list_sheets` links the sheet to the conversation (`opened` or `read`).
  """

  import SpreadSheetAi.Agents.Tools.Support

  alias LangChain.Function
  alias SpreadSheetAi.Agents.Tools.Support
  alias SpreadSheetAi.Sheets

  @doc "The read tools' definitions."
  @spec functions() :: [Function.t()]
  def functions do
    [
      Function.new!(%{
        name: "list_sheets",
        display_text: "Listing sheets",
        description:
          "List every sheet in the system with its id, name, and number of rows and columns. " <>
            "Use it to find a sheet that isn't in <linked_sheets>.",
        parameters_schema: object(%{}),
        function: &list_sheets/2
      }),
      Function.new!(%{
        name: "open_sheet",
        display_text: "Opening a sheet",
        description:
          "Open a sheet: link it to this conversation and return its structure " <>
            "(columns with types, row count, version). No cell values.",
        parameters_schema: object(%{"sheet_id" => sheet_id_schema()}, ["sheet_id"]),
        function: &open_sheet/2
      }),
      Function.new!(%{
        name: "read_rows",
        display_text: "Reading rows",
        description:
          "Read a page of rows in order: each row's label and its values by column name. " <>
            "The page size is capped; use offset to page. Name only the columns you need.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "offset" => position_schema("Index of the first row to read. Default 0."),
              "limit" => %{
                "type" => "integer",
                "minimum" => 1,
                "description" => "How many rows to read. Default and maximum: the page cap."
              },
              "columns" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Column names to include. Default: every column."
              }
            },
            ["sheet_id"]
          ),
        function: &read_rows/2
      }),
      Function.new!(%{
        name: "read_cells",
        display_text: "Reading cells",
        description: "Read specific cells: every listed row label × every listed column name.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "rows" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Row labels (line items)."
              },
              "columns" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Column names."
              }
            },
            ["sheet_id", "rows", "columns"]
          ),
        function: &read_cells/2
      }),
      Function.new!(%{
        name: "find_rows",
        display_text: "Searching rows",
        description:
          "Find rows whose label contains the query (case-insensitive). Returns the labels.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "query" => %{"type" => "string", "description" => "Text to look for in labels."}
            },
            ["sheet_id", "query"]
          ),
        function: &find_rows/2
      })
    ]
  end

  @doc "`list_sheets`: `[{id, name, rows, columns}]`."
  @spec list_sheets(map(), map()) :: Support.result()
  def list_sheets(_args, _context) do
    Sheets.list_sheets()
    |> Enum.map(&%{id: &1.id, name: &1.name, rows: &1.row_count, columns: &1.column_count})
    |> json()
  end

  @doc "`open_sheet`: the sheet's structure. Links it as `opened`."
  @spec open_sheet(map(), map()) :: Support.result()
  def open_sheet(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id") do
      case Sheets.describe(sheet_id) do
        {:ok, description} ->
          touch(context, sheet_id, :opened)
          json(structure(description))

        error ->
          error(error, sheet_id)
      end
    end
  end

  @doc "`read_rows`: `{rows: [{label, values}], total, offset}`. Links the sheet as `read`."
  @spec read_rows(map(), map()) :: Support.result()
  def read_rows(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, offset} <- fetch_integer(args, "offset", 0),
         {:ok, limit} <- fetch_integer(args, "limit", 1),
         {:ok, columns} <- fetch_strings(args, "columns", :optional) do
      opts = Enum.reject([offset: offset, limit: limit, columns: columns], &is_nil(elem(&1, 1)))
      read(context, sheet_id, Sheets.read_rows(sheet_id, opts), & &1)
    end
  end

  @doc "`read_cells`: `{cells: {label: {column: value}}}`. Links the sheet as `read`."
  @spec read_cells(map(), map()) :: Support.result()
  def read_cells(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, labels} <- fetch_strings(args, "rows"),
         {:ok, columns} <- fetch_strings(args, "columns") do
      read(context, sheet_id, Sheets.read_cells(sheet_id, labels, columns), &%{cells: &1})
    end
  end

  @doc "`find_rows`: `{rows: [label], truncated}`. Links the sheet as `read`."
  @spec find_rows(map(), map()) :: Support.result()
  def find_rows(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, query} <- fetch_string(args, "query") do
      read(context, sheet_id, Sheets.find_rows(sheet_id, query), & &1)
    end
  end

  @doc "A sheet's structure as the tools report it."
  @spec structure(map()) :: map()
  def structure(description) do
    %{
      id: description.id,
      name: description.name,
      columns:
        Enum.map(
          description.columns,
          &%{name: &1.name, type: &1.column_type, is_label: &1.is_label}
        ),
      row_count: description.row_count,
      version: description.version
    }
  end

  defp read(context, sheet_id, {:ok, result}, shape) do
    touch(context, sheet_id, :read)
    json(shape.(result))
  end

  defp read(_context, sheet_id, error, _shape), do: error(error, sheet_id)
end
