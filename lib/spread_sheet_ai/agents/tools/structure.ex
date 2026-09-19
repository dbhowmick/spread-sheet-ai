defmodule SpreadSheetAi.Agents.Tools.Structure do
  @moduledoc """
  The copilot's structure tools (AI-3): `create_sheet`, `rename_sheet` and
  the column tools. A created sheet is owned by the conversation's creator
  (T-1) and linked as `created`; the other tools link it as `written`.
  """

  import SpreadSheetAi.Agents.Tools.Support

  alias LangChain.Function
  alias SpreadSheetAi.Agents.Tools.{Read, Support}
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.Reads

  @doc "The structure tools' definitions."
  @spec functions() :: [Function.t()]
  def functions do
    [
      Function.new!(%{
        name: "create_sheet",
        display_text: "Creating a sheet",
        description:
          "Create a sheet. Every sheet has one line-item (label) column of type text, " <>
            "first; add other columns and, optionally, rows in the same call.",
        parameters_schema:
          object(
            %{
              "name" => %{"type" => "string", "description" => "The sheet's name."},
              "label_column_name" => %{
                "type" => "string",
                "description" => ~s(The line-item column's name. Default "Line item".)
              },
              "columns" => %{
                "type" => "array",
                "description" => "Columns after the line-item column, in order.",
                "items" =>
                  object(
                    %{
                      "name" => %{"type" => "string"},
                      "type" => type_schema("The column's type.")
                    },
                    ["name", "type"]
                  )
              },
              "rows" => %{
                "type" => "array",
                "description" => "Initial rows, in order.",
                "items" => row_schema()
              }
            },
            ["name"]
          ),
        function: &create_sheet/2
      }),
      Function.new!(%{
        name: "rename_sheet",
        display_text: "Renaming a sheet",
        description: "Rename a sheet.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "name" => %{"type" => "string", "description" => "The new name."}
            },
            ["sheet_id", "name"]
          ),
        function: &rename_sheet/2
      }),
      Function.new!(%{
        name: "add_column",
        display_text: "Adding a column",
        description: "Add a column. Its cells start empty.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "name" => %{"type" => "string", "description" => "The column's name."},
              "type" => type_schema("The column's type."),
              "position" =>
                position_schema(
                  "0-based index to insert at (0 is the line-item column's place). Default: last."
                )
            },
            ["sheet_id", "name", "type"]
          ),
        function: &add_column/2
      }),
      Function.new!(%{
        name: "rename_column",
        display_text: "Renaming a column",
        description: "Rename a column, including the line-item column.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "column" => %{"type" => "string", "description" => "The column's current name."},
              "new_name" => %{"type" => "string", "description" => "The new name."}
            },
            ["sheet_id", "column", "new_name"]
          ),
        function: &rename_column/2
      }),
      Function.new!(%{
        name: "change_column_type",
        display_text: "Changing a column type",
        description:
          "Change a column's type, converting its values. Fails, changing nothing, " <>
            "if a value can't be converted. The line-item column stays text.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "column" => %{"type" => "string", "description" => "The column's name."},
              "type" => type_schema("The new type.")
            },
            ["sheet_id", "column", "type"]
          ),
        function: &change_column_type/2
      }),
      Function.new!(%{
        name: "move_column",
        display_text: "Moving a column",
        description: "Move a column to a new 0-based position.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "column" => %{"type" => "string", "description" => "The column's name."},
              "position" => position_schema("The column's new 0-based index.")
            },
            ["sheet_id", "column", "position"]
          ),
        function: &move_column/2
      }),
      Function.new!(%{
        name: "delete_column",
        display_text: "Deleting a column",
        description: "Delete a column and its values. The line-item column can't be deleted.",
        parameters_schema:
          object(
            %{
              "sheet_id" => sheet_id_schema(),
              "column" => %{"type" => "string", "description" => "The column's name."}
            },
            ["sheet_id", "column"]
          ),
        function: &delete_column/2
      })
    ]
  end

  @doc "A new row: its label and its values by column name."
  @spec row_schema() :: map()
  def row_schema do
    object(
      %{
        "label" => %{"type" => "string", "description" => "The row's line-item label (unique)."},
        "values" => values_schema()
      },
      ["label"]
    )
  end

  @doc """
  `create_sheet`: the new sheet's id and structure. Owned by the
  conversation's creator; linked as `created`.
  """
  @spec create_sheet(map(), map()) :: Support.result()
  def create_sheet(args, context) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, columns} <- fetch_objects(args, "columns", :optional),
         {:ok, rows} <- fetch_objects(args, "rows", :optional),
         {:ok, conversation} <- conversation(context) do
      params =
        %{
          "name" => name,
          "label_column_name" => Map.get(args, "label_column_name"),
          "columns" => columns && Enum.map(columns, &column_params/1),
          "rows" => rows
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      case Sheets.create_sheet(params, conversation.user, actor(conversation)) do
        {:ok, state} ->
          touch(context, state.id, :created)
          json(Read.structure(Reads.describe(state)))

        error ->
          error(error, nil)
      end
    end
  end

  # The tools call a column's type `type`; the contract calls it `column_type`.
  defp column_params(column) do
    column
    |> Map.take(["name"])
    |> Map.put("column_type", Map.get(column, "type"))
  end

  @doc "`rename_sheet`: `{version}`."
  @spec rename_sheet(map(), map()) :: Support.result()
  def rename_sheet(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, name} <- fetch_string(args, "name") do
      write(context, sheet_id, %{"type" => "rename_sheet", "name" => name}, &version/2)
    end
  end

  @doc "`add_column`: `{version}`."
  @spec add_column(map(), map()) :: Support.result()
  def add_column(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, name} <- fetch_string(args, "name"),
         {:ok, type} <- fetch_type(args, "type"),
         {:ok, position} <- fetch_integer(args, "position", 0) do
      op = %{
        "type" => "add_column",
        "name" => name,
        "column_type" => type,
        "position" => position
      }

      write(context, sheet_id, op, &version/2)
    end
  end

  @doc "`rename_column`: `{version}`."
  @spec rename_column(map(), map()) :: Support.result()
  def rename_column(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, column} <- fetch_string(args, "column"),
         {:ok, name} <- fetch_string(args, "new_name") do
      op = %{"type" => "rename_column", "column" => column, "name" => name}
      write(context, sheet_id, op, &version/2)
    end
  end

  @doc "`change_column_type`: `{version}`."
  @spec change_column_type(map(), map()) :: Support.result()
  def change_column_type(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, column} <- fetch_string(args, "column"),
         {:ok, type} <- fetch_type(args, "type") do
      op = %{"type" => "change_column_type", "column" => column, "column_type" => type}
      write(context, sheet_id, op, &version/2)
    end
  end

  @doc "`move_column`: `{version}`."
  @spec move_column(map(), map()) :: Support.result()
  def move_column(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, column} <- fetch_string(args, "column"),
         {:ok, position} <- fetch_integer(args, "position", 0, :required) do
      op = %{"type" => "move_column", "column" => column, "position" => position}
      write(context, sheet_id, op, &version/2)
    end
  end

  @doc "`delete_column`: `{version}`."
  @spec delete_column(map(), map()) :: Support.result()
  def delete_column(args, context) do
    with {:ok, sheet_id} <- fetch_string(args, "sheet_id"),
         {:ok, column} <- fetch_string(args, "column") do
      write(context, sheet_id, %{"type" => "delete_column", "column" => column}, &version/2)
    end
  end
end
