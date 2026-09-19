defmodule SpreadSheetAi.SheetsFixtures do
  @moduledoc """
  Test fixtures for sheets, columns, rows and change-log entries.

  `created_sheet_fixture/1` creates a sheet the way the app does, through
  `Sheets.create_sheet/3` (version 1 and its change-log entry). The other
  fixtures insert straight through the schema changesets, for schema tests
  that need rows the engine would never write.
  """

  alias SpreadSheetAi.AuthFixtures
  alias SpreadSheetAi.Repo
  alias SpreadSheetAi.Sheets

  alias SpreadSheetAi.Sheets.{
    Change,
    ChangeQueries,
    Column,
    ColumnQueries,
    Row,
    RowQueries,
    Sheet
  }

  @doc """
  Creates a sheet through `Sheets.create_sheet/3` and returns its `State`.
  `params` are `parse_create` params (string keys; a unique `"name"` is
  filled in). Pass `owner: user` to reuse an owner; otherwise one is created.
  """
  def created_sheet_fixture(params \\ %{}) do
    {owner, params} = Map.pop_lazy(params, :owner, &AuthFixtures.verified_user_fixture/0)
    params = Map.merge(%{"name" => "Sheet #{AuthFixtures.unique()}"}, params)
    {:ok, state} = Sheets.create_sheet(params, owner)
    state
  end

  @doc """
  Inserts a sheet with a `"Line item"` text label column at position 0.
  Pass `owner: user` to reuse an owner; otherwise one is created.
  """
  def sheet_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    owner = Map.get_lazy(attrs, :owner, &AuthFixtures.verified_user_fixture/0)

    sheet =
      %Sheet{}
      |> Sheet.create_changeset(%{
        name: Map.get(attrs, :name, "Sheet #{AuthFixtures.unique()}"),
        owner_id: owner.id
      })
      |> Repo.insert!()

    column_fixture(sheet, %{name: "Line item", column_type: "text", is_label: true, position: 0})
    sheet
  end

  @doc "Inserts a column at the next position (a unique `number` column by default)."
  def column_fixture(%Sheet{} = sheet, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Column #{AuthFixtures.unique()}",
        column_type: "number",
        position: next_position(Column, sheet.id)
      })

    %Column{} |> Column.changeset(Map.put(attrs, :sheet_id, sheet.id)) |> Repo.insert!()
  end

  @doc "Inserts a row at the next position (a unique label, no values, by default)."
  def row_fixture(%Sheet{} = sheet, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        label: "Row #{AuthFixtures.unique()}",
        position: next_position(Row, sheet.id),
        values: %{}
      })

    %Row{} |> Row.changeset(Map.put(attrs, :sheet_id, sheet.id)) |> Repo.insert!()
  end

  @doc "Inserts a change-log entry for the next version, made by the sheet's owner by default."
  def change_fixture(%Sheet{} = sheet, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        version: next_version(sheet.id),
        op: %{"type" => "rename_sheet", "name" => sheet.name},
        actor_type: "user",
        actor_user_id: sheet.owner_id
      })

    %Change{} |> Change.changeset(Map.put(attrs, :sheet_id, sheet.id)) |> Repo.insert!()
  end

  defp next_position(Column, sheet_id),
    do: sheet_id |> ColumnQueries.for_sheet() |> Repo.aggregate(:count)

  defp next_position(Row, sheet_id),
    do: sheet_id |> RowQueries.for_sheet() |> Repo.aggregate(:count)

  defp next_version(sheet_id) do
    (sheet_id |> ChangeQueries.for_sheet() |> Repo.aggregate(:max, :version) || 0) + 1
  end
end
