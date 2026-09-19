defmodule SpreadSheetAi.Agents.Tools.Rows do
  @moduledoc """
  The copilot's row tools (AI-3): `add_rows`, `delete_rows` and `move_row`.
  Rows are named by their line-item label. Each links the sheet as
  `written`.
  """

  import SpreadSheetAi.Agents.Tools.Support

  alias LangChain.Function
  alias SpreadSheetAi.Agents.Tools.{Structure, Support}

  @doc "The row tools' definitions."
  @spec functions() :: [Function.t()]
  def functions do
    [
      Function.new!(%{
        name: "add_rows",
        display_text: "Adding rows",
        description:
          "Add many rows in one call, each with its label and any values. " <>
            "Labels must be unique in the sheet.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "rows" => %{
                "type" => "array",
                "minItems" => 1,
                "items" => Structure.row_schema()
              },
              "position" =>
                position_schema("0-based index to insert the first row at. Default: at the end.")
            },
            ["sheet_id", "rows"]
          ),
        function: &add_rows/2
      }),
      Function.new!(%{
        name: "delete_rows",
        display_text: "Deleting rows",
        description: "Delete rows by label.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "labels" => %{
                "type" => "array",
                "minItems" => 1,
                "items" => %{"type" => "string"},
                "description" => "The labels of the rows to delete."
              }
            },
            ["sheet_id", "labels"]
          ),
        function: &delete_rows/2
      }),
      Function.new!(%{
        name: "move_row",
        display_text: "Moving a row",
        description: "Move a row to a new 0-based position.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "label" => %{"type" => "string", "description" => "The row's label."},
              "position" => position_schema("The row's new 0-based index.")
            },
            ["sheet_id", "label", "position"]
          ),
        function: &move_row/2
      })
    ]
  end

  @doc "`add_rows`: `{version, added}`."
  @spec add_rows(map(), map()) :: Support.result()
  def add_rows(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, rows} <- fetch_objects(args, "rows"),
         {:ok, position} <- fetch_integer(args, "position", 0) do
      op = %{"type" => "add_rows", "rows" => rows, "position" => position}

      write(context, sheet_id, op, fn version, applied_op ->
        %{version: version, added: length(applied_op["rows"])}
      end)
    end
  end

  @doc "`delete_rows`: `{version, deleted}`."
  @spec delete_rows(map(), map()) :: Support.result()
  def delete_rows(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, labels} <- fetch_strings(args, "labels") do
      write(context, sheet_id, %{"type" => "delete_rows", "labels" => labels}, fn
        version, applied_op -> %{version: version, deleted: length(applied_op["row_ids"])}
      end)
    end
  end

  @doc "`move_row`: `{version}`."
  @spec move_row(map(), map()) :: Support.result()
  def move_row(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, label} <- fetch_string(args, "label"),
         {:ok, position} <- fetch_integer(args, "position", 0, :required) do
      op = %{"type" => "move_row", "label" => label, "position" => position}
      write(context, sheet_id, op, &version/2)
    end
  end
end
