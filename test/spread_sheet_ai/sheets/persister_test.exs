defmodule SpreadSheetAi.Sheets.PersisterTest do
  use SpreadSheetAi.DataCase, async: true

  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{Actor, ChangeQueries, ColumnQueries, Engine, Op, Persister}
  alias SpreadSheetAi.Sheets.{RowQueries, SheetQueries, State}

  # The parts of a State that the database holds.
  @stored [
    :id,
    :name,
    :owner_id,
    :version,
    :label_column_id,
    :column_order,
    :columns_by_id,
    :column_id_by_name_key,
    :row_order,
    :rows_by_id,
    :row_id_by_label_key
  ]

  setup do
    state =
      created_sheet_fixture(%{
        "columns" => [%{"name" => "Q1", "column_type" => "number"}],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200}},
          %{"label" => "Cost", "values" => %{"Q1" => 400}},
          %{"label" => "Rent", "values" => %{}}
        ]
      })

    owner = SpreadSheetAi.Repo.get!(SpreadSheetAi.Accounts.User, state.owner_id)
    %{state: state, actor: Actor.user(owner)}
  end

  test "create writes the sheet, its columns and rows, and change 1", %{state: state} do
    assert stored(db_state(state.id)) == stored(state)

    assert [change] = state.id |> ChangeQueries.for_sheet() |> Repo.all()
    assert change.version == 1
    assert change.op["type"] == "create_sheet"
    assert change.actor_type == "user"
    assert change.actor_user_id == state.owner_id
  end

  test "every effect writes what the engine applied", %{state: state, actor: actor} do
    q1 = column_id(state, "Q1")
    [revenue, cost, rent] = state.row_order
    q2 = Ecto.UUID.generate()
    new_row = Ecto.UUID.generate()

    ops = [
      %{"type" => "rename_sheet", "name" => "Budget"},
      %{
        "type" => "add_column",
        "id" => q2,
        "name" => "Q2",
        "column_type" => "text",
        "position" => 1
      },
      %{"type" => "rename_column", "column_id" => q1, "name" => "Quarter 1"},
      %{
        "type" => "add_rows",
        "position" => 0,
        "rows" => [%{"id" => new_row, "cells" => %{state.label_column_id => "Tax", q2 => "ok"}}]
      },
      %{
        "type" => "set_cells",
        "cells" => [
          %{"row_id" => rent, "column_id" => q1, "value" => 90},
          %{"row_id" => revenue, "column_id" => q1, "value" => nil}
        ]
      },
      %{"type" => "change_column_type", "column_id" => q1, "column_type" => "text"},
      %{"type" => "move_column", "column_id" => state.label_column_id, "position" => 2},
      %{"type" => "move_row", "row_id" => new_row, "position" => 3},
      %{"type" => "delete_column", "column_id" => q2},
      %{"type" => "delete_rows", "row_ids" => [cost]}
    ]

    final = Enum.reduce(ops, state, &persist!(&2, &1, actor))

    assert final.version == 11
    assert final.name == "Budget"

    versions =
      state.id |> ChangeQueries.for_sheet() |> ChangeQueries.ordered() |> Repo.all()

    assert Enum.map(versions, & &1.version) == Enum.to_list(1..11)
    assert Enum.map(tl(versions), & &1.op["type"]) == Enum.map(ops, & &1["type"])
  end

  test "a label swap is written in two steps", %{state: state, actor: actor} do
    [revenue, cost | _] = state.row_order
    label = state.label_column_id

    swapped =
      persist!(
        state,
        %{
          "type" => "set_cells",
          "cells" => [
            %{"row_id" => revenue, "column_id" => label, "value" => "Cost"},
            %{"row_id" => cost, "column_id" => label, "value" => "Revenue"}
          ]
        },
        actor
      )

    assert state.id |> db_state() |> State.rows() |> Enum.map(& &1.label) ==
             ["Cost", "Revenue", "Rent"]

    assert Repo.all(RowQueries.for_sheet(state.id)) |> Enum.map(& &1.label_key) |> Enum.sort() ==
             ["cost", "rent", "revenue"]

    assert swapped.version == 2
  end

  test "a stale version writes nothing", %{state: state, actor: actor} do
    {:ok, op} = Op.parse(%{"type" => "rename_sheet", "name" => "Budget"})
    {:ok, new_state, applied, effects} = Engine.apply(state, op, Sheets.limits())

    Repo.update_all(SheetQueries.by_id(state.id), inc: [version: 1])

    assert Persister.apply(state.id, new_state.version, effects, applied, actor) ==
             {:error, :version_conflict}

    assert %{name: name, version: 2} = Repo.one(SheetQueries.by_id(state.id))
    assert name == state.name
    assert state.id |> ChangeQueries.for_sheet() |> Repo.aggregate(:count) == 1
  end

  test "records the actor and client_op_id in the change log", %{state: state} do
    conversation_id = Ecto.UUID.generate()
    client_op_id = Ecto.UUID.generate()
    {:ok, op} = Op.parse(%{"type" => "rename_sheet", "name" => "Budget"})
    {:ok, new_state, applied, effects} = Engine.apply(state, op, Sheets.limits())

    assert {:ok, %DateTime{}} =
             Persister.apply(
               state.id,
               new_state.version,
               effects,
               applied,
               Actor.agent(conversation_id, "Budget planning"),
               client_op_id: client_op_id
             )

    change =
      state.id
      |> ChangeQueries.for_sheet()
      |> ChangeQueries.ordered()
      |> Repo.all()
      |> List.last()

    assert %{
             version: 2,
             op: ^applied,
             actor_type: "agent",
             actor_user_id: nil,
             conversation_id: ^conversation_id,
             client_op_id: ^client_op_id
           } = change
  end

  defp persist!(state, op_map, actor) do
    {:ok, op} = Op.parse(op_map)
    {:ok, new_state, applied, effects} = Engine.apply(state, op, Sheets.limits())

    assert {:ok, _updated_at} =
             Persister.apply(state.id, new_state.version, effects, applied, actor)

    assert stored(db_state(state.id)) == stored(new_state), "after #{op_map["type"]}"
    new_state
  end

  defp db_state(sheet_id) do
    sheet = sheet_id |> SheetQueries.by_id() |> SheetQueries.with_owner() |> Repo.one!()
    columns = sheet_id |> ColumnQueries.for_sheet() |> Repo.all()
    rows = sheet_id |> RowQueries.for_sheet() |> Repo.all()
    State.load(sheet, columns, rows)
  end

  defp stored(state), do: Map.take(state, @stored)

  defp column_id(state, name) do
    {:ok, column} = State.fetch_column_by_name(state, name)
    column.id
  end
end
