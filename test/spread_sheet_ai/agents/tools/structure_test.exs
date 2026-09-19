defmodule SpreadSheetAi.Agents.Tools.StructureTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Agents.Tools.Structure
  alias SpreadSheetAi.Conversations
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{ChangeQueries, SheetQueries}

  setup do
    creator = verified_user_fixture()
    conversation = conversation_fixture(creator)

    {:ok, conversation} =
      Conversations.put_title(Scope.for_user(creator), conversation.id, "Budget")

    :ok = Conversations.subscribe_events(conversation.id)

    sheet =
      created_sheet_fixture(%{
        "name" => "P&L 2026",
        "columns" => [
          %{"name" => "Q1", "column_type" => "number"},
          %{"name" => "Note", "column_type" => "text"}
        ],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200, "Note" => "up"}},
          %{"label" => "Payroll", "values" => %{"Note" => "tbd"}}
        ]
      })

    :ok = Sheets.subscribe(sheet.id)

    # Another participant's message started the run: ownership and the actor
    # still come from the conversation.
    context = tool_context(conversation, verified_user_fixture())

    %{sheet: sheet, conversation: conversation, creator: creator, context: context}
  end

  describe "create_sheet" do
    test "creates the sheet with columns and rows, owned by the conversation's creator", %{
      conversation: conversation,
      creator: creator,
      context: context
    } do
      args = %{
        "name" => "Hiring plan",
        "label_column_name" => "Role",
        "columns" => [
          %{"name" => "Headcount", "type" => "number"},
          %{"name" => "Start", "type" => "date"}
        ],
        "rows" => [%{"label" => "Engineer", "values" => %{"Headcount" => 3}}]
      }

      assert {:ok, json} = Structure.create_sheet(args, context)

      assert %{
               "id" => id,
               "name" => "Hiring plan",
               "columns" => [
                 %{"name" => "Role", "type" => "text", "is_label" => true},
                 %{"name" => "Headcount", "type" => "number", "is_label" => false},
                 %{"name" => "Start", "type" => "date", "is_label" => false}
               ],
               "row_count" => 1,
               "version" => 1
             } = Jason.decode!(json)

      creator_id = creator.id
      assert {:ok, %{owner: %{id: ^creator_id}}} = Sheets.snapshot(id)

      conversation_id = conversation.id

      assert [%{actor_type: "agent", actor_user_id: nil, conversation_id: ^conversation_id}] =
               id |> ChangeQueries.for_sheet() |> Repo.all()

      assert_receive {:focus_sheet, ^id, :created}
      assert_receive {:sheets_changed}

      assert [%{sheet: %{id: ^id}, created_here: true, last_access: "created"}] =
               Sheets.list_links(conversation.id)
    end

    test "only a name is required", %{context: context} do
      assert {:ok, json} = Structure.create_sheet(%{"name" => "Empty"}, context)

      assert %{"columns" => [%{"name" => "Line item", "is_label" => true}], "row_count" => 0} =
               Jason.decode!(json)
    end

    test "invalid params are errors that name the field, and nothing is created", %{
      conversation: conversation,
      context: context
    } do
      args = %{"name" => "Bad", "columns" => [%{"name" => "Q1", "type" => "money"}]}

      assert {:error, "ERROR validation_failed: \"columns\" column_type must be one of" <> _} =
               Structure.create_sheet(args, context)

      args = %{"name" => "Bad", "rows" => [%{"label" => "A", "values" => %{"Q9" => 1}}]}
      assert {:error, "ERROR unknown_column: " <> _} = Structure.create_sheet(args, context)

      assert {:error, "ERROR invalid_arguments: \"name\" is required" <> _} =
               Structure.create_sheet(%{}, context)

      assert Sheets.list_links(conversation.id) == []
      refute_receive {:focus_sheet, _, _}
    end
  end

  test "rename_sheet", %{sheet: sheet, conversation: conversation, context: context} do
    assert {:ok, ~s({"version":2})} =
             Structure.rename_sheet(%{"sheet_id" => sheet.id, "name" => "P&L"}, context)

    assert %{name: "P&L"} = Repo.one(SheetQueries.by_id(sheet.id))

    # The change is made as the conversation, with its title (AI-6).
    conversation_id = conversation.id

    assert_receive {:op_applied,
                    %{
                      version: 2,
                      actor: %{
                        type: :agent,
                        conversation_id: ^conversation_id,
                        conversation_title: "Budget"
                      }
                    }}

    assert_written(sheet.id, context)
  end

  describe "column tools" do
    test "add, rename, retype, move and delete a column", %{sheet: sheet, context: context} do
      id = sheet.id

      assert {:ok, ~s({"version":2})} =
               Structure.add_column(
                 %{"sheet_id" => id, "name" => "Q2", "type" => "number", "position" => 2},
                 context
               )

      assert {:ok, ~s({"version":3})} =
               Structure.rename_column(
                 %{"sheet_id" => id, "column" => "q2", "new_name" => "Apr-Jun"},
                 context
               )

      assert {:ok, ~s({"version":4})} =
               Structure.change_column_type(
                 %{"sheet_id" => id, "column" => "Q1", "type" => "text"},
                 context
               )

      assert {:ok, ~s({"version":5})} =
               Structure.move_column(
                 %{"sheet_id" => id, "column" => "Note", "position" => 1},
                 context
               )

      assert {:ok, ~s({"version":6})} =
               Structure.delete_column(%{"sheet_id" => id, "column" => "Apr-Jun"}, context)

      assert {:ok, %{columns: columns}} = Sheets.describe(id)

      assert Enum.map(columns, &{&1.name, &1.column_type}) == [
               {"Line item", "text"},
               {"Note", "text"},
               {"Q1", "text"}
             ]

      assert {:ok, %{"Revenue" => %{"Q1" => "1200"}}} =
               Sheets.read_cells(id, ["Revenue"], ["Q1"])

      assert_written(id, context)
    end

    test "rejected ops come back as errors the model can act on", %{
      sheet: sheet,
      context: context
    } do
      id = sheet.id

      assert {:error, "ERROR label_column_protected: " <> _} =
               Structure.delete_column(%{"sheet_id" => id, "column" => "Line item"}, context)

      assert {:error, "ERROR type_conversion_failed: " <> _} =
               Structure.change_column_type(
                 %{"sheet_id" => id, "column" => "Note", "type" => "number"},
                 context
               )

      assert {:error, "ERROR duplicate_column_name: " <> _} =
               Structure.rename_column(
                 %{"sheet_id" => id, "column" => "Q1", "new_name" => "note"},
                 context
               )

      assert {:error, "ERROR invalid_position: " <> _} =
               Structure.move_column(
                 %{"sheet_id" => id, "column" => "Q1", "position" => 9},
                 context
               )

      assert {:error, text} =
               Structure.delete_column(%{"sheet_id" => id, "column" => "Q3"}, context)

      assert text =~ "Existing columns: Line item, Q1, Note."

      refute_receive {:op_applied, _}
      refute_receive {:focus_sheet, _, _}
      assert Sheets.list_links(context.conversation_id) == []
    end

    test "bad argument types are rejected", %{sheet: sheet, context: context} do
      id = sheet.id

      assert {:error, "ERROR invalid_arguments: \"type\" must be one of" <> _} =
               Structure.add_column(
                 %{"sheet_id" => id, "name" => "Q2", "type" => "money"},
                 context
               )

      assert {:error, "ERROR invalid_arguments: \"position\" is required" <> _} =
               Structure.move_column(%{"sheet_id" => id, "column" => "Q1"}, context)

      assert {:error, "ERROR invalid_arguments: \"position\" must be an integer" <> _} =
               Structure.add_column(
                 %{"sheet_id" => id, "name" => "Q2", "type" => "number", "position" => 1.5},
                 context
               )

      assert {:error, "ERROR invalid_arguments: \"column\" must be a string" <> _} =
               Structure.delete_column(%{"sheet_id" => id, "column" => ["Q1"]}, context)
    end
  end

  defp assert_written(sheet_id, context) do
    assert_receive {:focus_sheet, ^sheet_id, :written}
    assert_receive {:sheets_changed}

    assert [%{sheet: %{id: ^sheet_id}, created_here: false, last_access: "written"}] =
             Sheets.list_links(context.conversation_id)
  end
end
