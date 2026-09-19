defmodule SpreadSheetAi.Agents.Tools.Cells do
  @moduledoc """
  The copilot's `set_cells` tool (AI-3): many cells in one call, each by
  row label and column name. Links the sheet as `written`.
  """

  import SpreadSheetAi.Agents.Tools.Support

  alias LangChain.Function
  alias SpreadSheetAi.Agents.Tools.Support

  @doc "The cell tools' definitions."
  @spec functions() :: [Function.t()]
  def functions do
    [
      Function.new!(%{
        name: "set_cells",
        display_text: "Updating cells",
        description:
          "Set many cells in one call. Setting the line-item column renames the row. " <>
            "null clears a cell. All cells change together, or none do.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "cells" => %{
                "type" => "array",
                "minItems" => 1,
                "items" =>
                  object(
                    %{
                      "row" => %{"type" => "string", "description" => "The row's label."},
                      "column" => %{"type" => "string", "description" => "The column's name."},
                      "value" => value_schema()
                    },
                    ["row", "column", "value"]
                  )
              }
            },
            ["sheet_id", "cells"]
          ),
        function: &set_cells/2
      })
    ]
  end

  @doc "`set_cells`: `{version, updated}`."
  @spec set_cells(map(), map()) :: Support.result()
  def set_cells(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, cells} <- fetch_objects(args, "cells") do
      write(context, sheet_id, %{"type" => "set_cells", "cells" => cells}, fn
        version, applied_op -> %{version: version, updated: length(applied_op["cells"])}
      end)
    end
  end
end
