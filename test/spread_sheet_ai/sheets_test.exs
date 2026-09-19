defmodule SpreadSheetAi.SheetsTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAi.DataCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{Actor, ChangeQueries, Op, Runtime, SheetQueries}

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

  defp changes(sheet_id),
    do: sheet_id |> ChangeQueries.for_sheet() |> ChangeQueries.ordered() |> Repo.all()
end
