defmodule SpreadSheetAi.Sheets.SchemaTest do
  use SpreadSheetAi.DataCase, async: true

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.AuthFixtures

  alias SpreadSheetAi.Sheets.{
    Change,
    ChangeQueries,
    Column,
    ColumnQueries,
    Row,
    RowQueries,
    Sheet
  }

  import SpreadSheetAi.SheetsFixtures

  setup do
    %{sheet: sheet_fixture()}
  end

  defp insert_column(sheet, attrs) do
    attrs = Enum.into(attrs, %{sheet_id: sheet.id, column_type: "number", position: 1})
    %Column{} |> Column.changeset(attrs) |> Repo.insert()
  end

  defp insert_row(sheet, attrs) do
    attrs = Enum.into(attrs, %{sheet_id: sheet.id, position: 0})
    %Row{} |> Row.changeset(attrs) |> Repo.insert()
  end

  defp insert_change(sheet, attrs) do
    attrs = Enum.into(attrs, %{sheet_id: sheet.id, op: %{"type" => "rename_sheet"}})
    %Change{} |> Change.changeset(attrs) |> Repo.insert()
  end

  describe "sheet_columns" do
    test "names are unique per sheet, trimmed and case-insensitive", %{sheet: sheet} do
      assert {:ok, column} = insert_column(sheet, name: "Q1")
      assert column.name_key == "q1"

      assert {:error, changeset} = insert_column(sheet, name: "  q1 ")
      assert "has already been taken" in errors_on(changeset).name

      assert {:ok, _} = insert_column(sheet_fixture(), name: "Q1")
    end

    test "a sheet has at most one label column", %{sheet: sheet} do
      assert {:error, changeset} =
               insert_column(sheet, name: "Other label", column_type: "text", is_label: true)

      assert "has already been taken" in errors_on(changeset).is_label

      assert {:ok, _} = insert_column(sheet, name: "Q1")
      assert {:ok, _} = insert_column(sheet, name: "Q2")
    end

    test "the label column must be text" do
      sheet =
        %Sheet{}
        |> Sheet.create_changeset(%{name: "No label", owner_id: AuthFixtures.user_fixture().id})
        |> Repo.insert!()

      assert {:error, changeset} =
               insert_column(sheet, name: "Label", column_type: "number", is_label: true)

      assert "is invalid" in errors_on(changeset).column_type
    end

    test "rejects an unknown column type", %{sheet: sheet} do
      assert {:error, changeset} = insert_column(sheet, name: "Q1", column_type: "currency")
      assert "is invalid" in errors_on(changeset).column_type
    end

    test "accepts a client-supplied id", %{sheet: sheet} do
      id = Ecto.UUID.generate()
      assert {:ok, %Column{id: ^id}} = insert_column(sheet, id: id, name: "Q1")
    end

    test "are listed in position order", %{sheet: sheet} do
      column_fixture(sheet, name: "Q2", position: 2)
      column_fixture(sheet, name: "Q1", position: 1)

      names =
        sheet.id |> ColumnQueries.for_sheet() |> ColumnQueries.ordered() |> Repo.all()

      assert Enum.map(names, & &1.name) == ["Line item", "Q1", "Q2"]
    end
  end

  describe "sheet_rows" do
    test "labels are unique per sheet, trimmed and case-insensitive", %{sheet: sheet} do
      assert {:ok, row} = insert_row(sheet, label: "Revenue")
      assert row.label_key == "revenue"

      assert {:error, changeset} = insert_row(sheet, label: "revenue ", position: 1)
      assert "has already been taken" in errors_on(changeset).label

      assert {:ok, _} = insert_row(sheet_fixture(), label: "Revenue")
    end

    test "a label is required", %{sheet: sheet} do
      assert {:error, changeset} = insert_row(sheet, label: "   ")
      assert "can't be blank" in errors_on(changeset).label
    end

    test "values round-trip through jsonb", %{sheet: sheet} do
      values = %{
        Ecto.UUID.generate() => "text",
        Ecto.UUID.generate() => 1200,
        Ecto.UUID.generate() => 12.5,
        Ecto.UUID.generate() => true,
        Ecto.UUID.generate() => "2026-09-20"
      }

      row = row_fixture(sheet, label: "Revenue", values: values)

      assert [%Row{values: ^values}] =
               sheet.id |> RowQueries.for_sheet() |> RowQueries.ordered() |> Repo.all()

      assert row.values == values
    end

    test "values default to an empty map", %{sheet: sheet} do
      {:ok, row} = insert_row(sheet, label: "Revenue")
      assert Repo.reload!(row).values == %{}
    end
  end

  describe "sheet_changes" do
    test "one change per version per sheet", %{sheet: sheet} do
      change_fixture(sheet, version: 1)

      assert {:error, changeset} =
               insert_change(sheet, version: 1, actor_type: "user", actor_user_id: sheet.owner_id)

      assert "has already been taken" in errors_on(changeset).version

      assert {:ok, _} =
               insert_change(sheet_fixture(),
                 version: 1,
                 actor_type: "user",
                 actor_user_id: sheet.owner_id
               )
    end

    test "a user change needs actor_user_id", %{sheet: sheet} do
      assert {:error, changeset} = insert_change(sheet, version: 1, actor_type: "user")
      assert "can't be blank" in errors_on(changeset).actor_user_id
    end

    test "an agent change needs conversation_id", %{sheet: sheet} do
      assert {:error, changeset} = insert_change(sheet, version: 1, actor_type: "agent")
      assert "can't be blank" in errors_on(changeset).conversation_id

      assert {:ok, change} =
               insert_change(sheet,
                 version: 1,
                 actor_type: "agent",
                 conversation_id: Ecto.UUID.generate()
               )

      assert change.actor_user_id == nil
    end

    test "rejects an unknown actor type", %{sheet: sheet} do
      assert {:error, changeset} = insert_change(sheet, version: 1, actor_type: "robot")
      assert "is invalid" in errors_on(changeset).actor_type
    end

    test "are listed in version order", %{sheet: sheet} do
      change_fixture(sheet)
      change_fixture(sheet)
      change_fixture(sheet)

      versions =
        sheet.id |> ChangeQueries.for_sheet() |> ChangeQueries.ordered() |> Repo.all()

      assert Enum.map(versions, & &1.version) == [1, 2, 3]
    end
  end

  describe "deletes" do
    test "deleting a sheet removes its columns, rows and changes", %{sheet: sheet} do
      column_fixture(sheet)
      row_fixture(sheet)
      change_fixture(sheet)

      Repo.delete!(sheet)

      assert Repo.aggregate(ColumnQueries.for_sheet(sheet.id), :count) == 0
      assert Repo.aggregate(RowQueries.for_sheet(sheet.id), :count) == 0
      assert Repo.aggregate(ChangeQueries.for_sheet(sheet.id), :count) == 0
    end

    test "a user who owns a sheet can't be deleted", %{sheet: sheet} do
      assert_raise Ecto.ConstraintError, ~r/sheets_owner_id_fkey/, fn ->
        Repo.delete(%User{id: sheet.owner_id})
      end
    end
  end
end
