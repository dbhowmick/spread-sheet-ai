defmodule SpreadSheetAiWeb.SheetJSONTest do
  use ExUnit.Case, async: true

  import SpreadSheetAi.EngineHelpers

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.Sheets.Actor
  alias SpreadSheetAiWeb.SheetJSON

  test "sheet/1 renders columns and rows in order, labels in cells, empty cells left out" do
    state =
      state!(%{
        "columns" => [%{"name" => "Q1", "column_type" => "number"}],
        "rows" => [
          %{"label" => "Revenue", "values" => %{"Q1" => 1200}},
          %{"label" => "Cost", "values" => %{}}
        ]
      })

    label = state.label_column_id
    q1 = column_id(state, "Q1")
    [revenue, cost] = state.row_order

    assert %{id: id, name: "P&L 2026", version: 1, columns: columns, rows: rows} =
             SheetJSON.sheet(state)

    assert id == state.id

    assert columns == [
             %{id: label, name: "Line item", column_type: "text", is_label: true},
             %{id: q1, name: "Q1", column_type: "number", is_label: false}
           ]

    assert rows == [
             %{id: revenue, cells: %{label => "Revenue", q1 => 1200}},
             %{id: cost, cells: %{label => "Cost"}}
           ]
  end

  describe "op_applied/1" do
    test "with a user actor" do
      user = %User{id: Ecto.UUID.generate(), display_name: "Alice", primary_email: "a@x.com"}
      op = %{"type" => "rename_sheet", "name" => "Budget"}

      assert SheetJSON.op_applied(%{
               version: 3,
               applied_op: op,
               actor: Actor.user(user),
               client_op_id: nil
             }) == %{
               version: 3,
               op: op,
               actor: %{type: "user", user: %{id: user.id, display_name: "Alice"}},
               client_op_id: nil
             }
    end

    test "with an agent actor" do
      conversation_id = Ecto.UUID.generate()

      assert %{actor: actor} =
               SheetJSON.op_applied(%{
                 version: 3,
                 applied_op: %{},
                 actor: Actor.agent(conversation_id, "Budget planning"),
                 client_op_id: nil
               })

      assert actor == %{
               type: "agent",
               conversation_id: conversation_id,
               conversation_title: "Budget planning"
             }
    end
  end

  test "user_ref/1 falls back to the email" do
    user = %User{id: Ecto.UUID.generate(), display_name: nil, primary_email: "bob@example.com"}
    assert SheetJSON.user_ref(user) == %{id: user.id, display_name: "bob@example.com"}
  end

  test "participants/1 sorts by name" do
    a = %{id: "2", display_name: "Alice"}
    b = %{id: "1", display_name: "Bob"}
    assert SheetJSON.participants([b, a]) == %{users: [a, b]}
  end
end
