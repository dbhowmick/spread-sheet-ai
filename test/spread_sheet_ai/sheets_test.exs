defmodule SpreadSheetAi.SheetsTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Conversations
  alias SpreadSheetAi.Sheets

  alias SpreadSheetAi.Sheets.{
    Actor,
    ChangeQueries,
    ConversationSheet,
    ConversationSheetQueries,
    Op,
    Runtime,
    SheetQueries
  }

  setup do
    owner = verified_user_fixture()

    sheet =
      created_sheet_fixture(%{
        "columns" => [%{"name" => "Q1", "column_type" => "number"}],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200}},
          %{"label" => "Cost", "values" => %{"Q1" => 400}}
        ],
        owner: owner
      })

    %{sheet: sheet, owner: owner, actor: Actor.user(owner)}
  end

  describe "create_sheet/3" do
    test "writes version 1 and the first change", %{sheet: sheet, owner: owner} do
      assert sheet.version == 1
      assert sheet.owner == %{id: owner.id, display_name: owner.display_name}
      assert %DateTime{} = sheet.inserted_at
      assert sheet.updated_at == sheet.inserted_at

      assert %{version: 1} = Repo.one(SheetQueries.by_id(sheet.id))
      assert [%{version: 1, op: %{"type" => "create_sheet"}}] = changes(sheet.id)
    end

    test "the snapshot loaded by the server matches what create returned", %{sheet: sheet} do
      assert Sheets.snapshot(sheet.id) == {:ok, sheet}
    end

    test "returns validation errors", %{owner: owner} do
      assert {:error, :validation_failed, _, %{field: "name"}} =
               Sheets.create_sheet(%{"name" => "  "}, owner)
    end

    test "records an agent actor", %{owner: owner} do
      conversation_id = Ecto.UUID.generate()
      actor = Actor.agent(conversation_id, "Budget planning")

      assert {:ok, sheet} = Sheets.create_sheet(%{"name" => "Budget"}, owner, actor)
      assert sheet.owner_id == owner.id

      assert [%{actor_type: "agent", actor_user_id: nil, conversation_id: ^conversation_id}] =
               changes(sheet.id)
    end
  end

  describe "apply_op/4" do
    test "persists, logs and broadcasts the op", %{sheet: sheet, actor: actor} do
      :ok = Sheets.subscribe(sheet.id)
      client_op_id = Ecto.UUID.generate()

      assert {:ok, 2, applied} =
               Sheets.apply_op(sheet.id, rename("Budget"), actor, client_op_id: client_op_id)

      assert applied == %{"type" => "rename_sheet", "name" => "Budget"}

      assert_receive {:op_applied,
                      %{
                        sheet_id: sheet_id,
                        version: 2,
                        applied_op: ^applied,
                        actor: ^actor,
                        client_op_id: ^client_op_id
                      }}

      assert sheet_id == sheet.id
      assert %{version: 2, name: "Budget"} = Repo.one(SheetQueries.by_id(sheet.id))

      assert [_, %{version: 2, op: ^applied, actor_type: "user", client_op_id: ^client_op_id}] =
               changes(sheet.id)

      assert {:ok, %{version: 2, name: "Budget"}} = Sheets.snapshot(sheet.id)
    end

    test "a rejected op writes and broadcasts nothing", %{sheet: sheet, actor: actor} do
      :ok = Sheets.subscribe(sheet.id)

      op = parse!(%{"type" => "delete_rows", "row_ids" => [Ecto.UUID.generate()]})
      assert {:error, :unknown_row, _, _} = Sheets.apply_op(sheet.id, op, actor)

      refute_receive {:op_applied, _}
      assert %{version: 1} = Repo.one(SheetQueries.by_id(sheet.id))
      assert length(changes(sheet.id)) == 1
      assert {:ok, %{version: 1}} = Sheets.snapshot(sheet.id)
    end

    @tag :capture_log
    test "a failed write is rejected, not broadcast, and the server reloads (P-2)",
         %{sheet: sheet, actor: actor} do
      {:ok, pid} = Runtime.ensure_started(sheet.id)
      ref = Process.monitor(pid)
      :ok = Sheets.subscribe(sheet.id)

      # Someone else moved the version on: the server's state is stale.
      Repo.update_all(SheetQueries.by_id(sheet.id), inc: [version: 1])

      assert {:error, :internal_error, _, _} = Sheets.apply_op(sheet.id, rename("Budget"), actor)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :persist_failed}}
      refute_receive {:op_applied, _}
      assert %{name: name} = Repo.one(SheetQueries.by_id(sheet.id))
      assert name == sheet.name

      assert {:ok, 3, _} = Sheets.apply_op(sheet.id, rename("Budget"), actor)
      assert_receive {:op_applied, %{version: 3}}
    end
  end

  describe "the sheet server" do
    test "rebuilds the same state after being killed (P-5)", %{sheet: sheet, actor: actor} do
      {:ok, 2, _} = Sheets.apply_op(sheet.id, rename("Budget"), actor)
      {:ok, before} = Sheets.snapshot(sheet.id)

      pid = Runtime.whereis(sheet.id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Sheets.snapshot(sheet.id) == {:ok, before}
      assert Runtime.whereis(sheet.id) not in [nil, pid]
    end

    test "stops when idle (P-4)", %{sheet: sheet} do
      {:ok, _} = Sheets.snapshot(sheet.id)
      pid = Runtime.whereis(sheet.id)
      ref = Process.monitor(pid)

      # The test config's idle_timeout is 200 ms.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert {:ok, %{version: 1}} = Sheets.snapshot(sheet.id)
    end

    test "a missing sheet is not_found and its server stops" do
      id = Ecto.UUID.generate()
      {:ok, pid} = Runtime.ensure_started(id)
      ref = Process.monitor(pid)

      assert {:error, :not_found, _, _} = Sheets.snapshot(id)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :not_found}}
    end

    test "a malformed id is not_found without starting a server", %{actor: actor} do
      assert {:error, :not_found, _, _} = Sheets.snapshot("nope")
      assert {:error, :not_found, _, _} = Sheets.apply_op("nope", rename("x"), actor)
      assert DynamicSupervisor.which_children(SpreadSheetAi.Sheets.ServerSupervisor) == []
    end

    test "concurrent writers get consecutive versions with no gaps (OP-4, P-2)",
         %{sheet: sheet, actor: actor} do
      {:ok, %{row_order: [revenue | _]} = state} = Sheets.snapshot(sheet.id)
      {:ok, q1} = SpreadSheetAi.Sheets.State.fetch_column_by_name(state, "Q1")

      results =
        1..50
        |> Task.async_stream(
          fn value ->
            op =
              parse!(%{
                "type" => "set_cells",
                "cells" => [%{"row_id" => revenue, "column_id" => q1.id, "value" => value}]
              })

            {:ok, version, _applied} = Sheets.apply_op(sheet.id, op, actor)
            {version, value}
          end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert results |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.to_list(2..51)
      assert Enum.map(changes(sheet.id), & &1.version) == Enum.to_list(1..51)
      assert %{version: 51} = Repo.one(SheetQueries.by_id(sheet.id))

      # The op that got the last version wins.
      {51, last_value} = List.keyfind(results, 51, 0)

      assert {:ok, %{"Revenue" => %{"Q1" => ^last_value}}} =
               Sheets.read_cells(sheet.id, ["Revenue"], ["Q1"])
    end
  end

  describe "reads" do
    test "are served through the server", %{sheet: sheet} do
      assert {:ok, %{row_count: 2, version: 1}} = Sheets.describe(sheet.id)

      assert {:ok, %{rows: [%{label: "Revenue", values: %{"Q1" => 1200}} | _], total: 2}} =
               Sheets.read_rows(sheet.id, limit: 1)

      assert {:ok, %{rows: ["Cost"], truncated: false}} = Sheets.find_rows(sheet.id, "cos")
      assert {:error, :unknown_row, _, _} = Sheets.read_cells(sheet.id, ["Tax"], ["Q1"])
    end
  end

  defp rename(name), do: parse!(%{"type" => "rename_sheet", "name" => name})

  defp parse!(op_map) do
    {:ok, op} = Op.parse(op_map)
    op
  end

  describe "link/3" do
    setup %{owner: owner}, do: %{conversation: conversation_fixture(owner)}

    test "the first link inserts one row per pair", %{sheet: sheet, conversation: conversation} do
      assert {:ok, %ConversationSheet{} = link} = Sheets.link(conversation.id, sheet.id, :opened)

      assert %{created_here: false, last_access: "opened"} = link
      assert link.first_accessed_at == link.last_accessed_at

      assert {:ok, %{created_here: true, last_access: "created"}} =
               Sheets.link(conversation_fixture().id, sheet.id, :created)
    end

    test "a repeat link updates the last access and keeps the first", %{
      sheet: sheet,
      conversation: conversation
    } do
      {:ok, first} = Sheets.link(conversation.id, sheet.id, :opened)

      backdated = DateTime.add(first.first_accessed_at, -60)

      Repo.update_all(ConversationSheetQueries.for_conversation(conversation.id),
        set: [first_accessed_at: backdated, last_accessed_at: backdated]
      )

      assert {:ok, link} = Sheets.link(conversation.id, sheet.id, :written)
      assert link.id == first.id
      assert %{last_access: "written", first_accessed_at: ^backdated} = link
      assert DateTime.after?(link.last_accessed_at, backdated)

      assert Repo.aggregate(ConversationSheetQueries.for_conversation(conversation.id), :count) ==
               1
    end

    test "created_here stays true once set", %{sheet: sheet, conversation: conversation} do
      {:ok, _link} = Sheets.link(conversation.id, sheet.id, :created)

      assert {:ok, %{created_here: true, last_access: "read"}} =
               Sheets.link(conversation.id, sheet.id, :read)

      other = created_sheet_fixture()
      {:ok, _link} = Sheets.link(conversation.id, other.id, :opened)
      assert {:ok, %{created_here: true}} = Sheets.link(conversation.id, other.id, :created)
    end

    test "an unknown or malformed id is not_found", %{sheet: sheet, conversation: conversation} do
      unknown = Ecto.UUID.generate()

      assert {:error, :not_found, "sheet not found", %{sheet_id: ^unknown}} =
               Sheets.link(conversation.id, unknown, :read)

      assert {:error, :not_found, "conversation not found", _meta} =
               Sheets.link(unknown, sheet.id, :read)

      assert {:error, :not_found, _message, %{sheet_id: "nope"}} =
               Sheets.link(conversation.id, "nope", :read)

      assert {:error, :invalid_op, _message, _meta} =
               Sheets.link(conversation.id, sheet.id, :deleted)
    end

    test "deleting the conversation deletes its links", %{
      sheet: sheet,
      conversation: conversation
    } do
      {:ok, _link} = Sheets.link(conversation.id, sheet.id, :opened)
      {:ok, _conversation} = Conversations.delete_conversation(conversation)

      assert Sheets.list_links(conversation.id) == []
    end

    test "list_links/1 returns LinkedSheets, most recently used first", %{
      sheet: sheet,
      owner: owner,
      conversation: conversation
    } do
      other = created_sheet_fixture(%{"name" => "Other"})
      {:ok, older} = Sheets.link(conversation.id, sheet.id, :created)

      Repo.update_all(ConversationSheetQueries.for_conversation(conversation.id),
        set: [last_accessed_at: DateTime.add(older.last_accessed_at, -60)]
      )

      {:ok, _link} = Sheets.link(conversation.id, other.id, :read)

      assert [first, second] = Sheets.list_links(conversation.id)
      assert %{sheet: %{id: other_id}, last_access: "read", created_here: false} = first
      assert other_id == other.id

      assert %{created_here: true, last_access: "created", sheet: summary} = second

      assert summary == %{
               id: sheet.id,
               name: sheet.name,
               owner: %{id: owner.id, display_name: owner.display_name},
               version: 1,
               row_count: 2,
               column_count: 2,
               inserted_at: sheet.inserted_at,
               updated_at: sheet.updated_at
             }

      assert Sheets.list_links("nope") == []
    end
  end

  defp changes(sheet_id),
    do: sheet_id |> ChangeQueries.for_sheet() |> ChangeQueries.ordered() |> Repo.all()
end
