defmodule SpreadSheetAiWeb.SheetChannelTest do
  # Sheet servers run under the global supervisor and share the sandbox.
  use SpreadSheetAiWeb.ChannelCase, async: false

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.SheetsFixtures

  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{Actor, Op, Runtime}
  alias SpreadSheetAiWeb.SheetChannel

  setup do
    alice = verified_user_fixture(%{display_name: "Alice"})

    sheet =
      created_sheet_fixture(%{
        "columns" => [%{"name" => "Q1", "column_type" => "number"}],
        "rows" => [%{"label" => "Revenue", "values" => %{"Q1" => 1200}}],
        owner: alice
      })

    %{alice: alice, sheet: sheet, revenue: hd(sheet.row_order), q1: q1(sheet)}
  end

  describe "join" do
    test "replies with the full snapshot (RT-3)", %{alice: alice, sheet: sheet} do
      assert {:ok, %{sheet: snapshot}, _socket} = join_as(alice, sheet.id)

      assert %{id: id, version: 1, columns: [_label, %{name: "Q1"}], rows: [row]} = snapshot
      assert id == sheet.id
      assert row.cells == %{sheet.label_column_id => "Revenue", q1(sheet) => 1200}
    end

    test "an unknown or malformed sheet is not_found", %{alice: alice} do
      for id <- [Ecto.UUID.generate(), "nope"] do
        assert {:error, %{errors: [%{code: "not_found"}]}} = join_as(alice, id)
      end
    end
  end

  describe "op" do
    setup %{alice: alice, sheet: sheet} do
      bob = verified_user_fixture(%{display_name: "Bob"})
      {:ok, _, alice_socket} = join_as(alice, sheet.id)
      {:ok, _, _bob_socket} = join_as(bob, sheet.id)
      %{socket: alice_socket}
    end

    test "is applied and pushed to every joined socket (RT-1, RT-2, RT-8)",
         %{socket: socket, alice: alice, revenue: revenue, q1: q1} do
      client_op_id = Ecto.UUID.generate()

      ref =
        push(socket, "op", %{
          "client_op_id" => client_op_id,
          "op" => set_cell(revenue, q1, 1500)
        })

      assert_reply ref, :ok, %{version: 2}

      expected = %{
        version: 2,
        op: %{
          "type" => "set_cells",
          "cells" => [%{"row_id" => revenue, "column_id" => q1, "value" => 1500}]
        },
        actor: %{type: "user", user: %{id: alice.id, display_name: "Alice"}},
        client_op_id: client_op_id
      }

      # Alice's and Bob's channels both push it.
      assert_push "op_applied", ^expected
      assert_push "op_applied", ^expected
      refute_push "op_applied", _
    end

    test "made elsewhere is pushed with its actor", %{sheet: sheet} do
      conversation_id = Ecto.UUID.generate()
      {:ok, op} = Op.parse(%{"type" => "rename_sheet", "name" => "Budget"})

      {:ok, 2, _} =
        Sheets.apply_op(sheet.id, op, Actor.agent(conversation_id, "Budget planning"))

      assert_push "op_applied", %{version: 2, actor: actor, client_op_id: nil}

      assert actor == %{
               type: "agent",
               conversation_id: conversation_id,
               conversation_title: "Budget planning"
             }
    end

    test "a rejected op replies with the error and pushes nothing",
         %{socket: socket, revenue: revenue} do
      q9 = Ecto.UUID.generate()
      ref = push(socket, "op", %{"op" => set_cell(revenue, q9, 1)})

      assert_reply ref, :error, %{errors: [error]}
      assert %{code: "unknown_column", field: nil, meta: %{column_id: ^q9}} = error
      assert error.message =~ q9
      refute_push "op_applied", _
    end

    test "a malformed op or client_op_id is invalid_op", %{
      socket: socket,
      revenue: revenue,
      q1: q1
    } do
      for payload <- [
            %{"op" => %{"type" => "explode"}},
            %{"op" => set_cell(revenue, q1, 1), "client_op_id" => "not-a-uuid"},
            %{"client_op_id" => Ecto.UUID.generate()}
          ] do
        ref = push(socket, "op", payload)
        assert_reply ref, :error, %{errors: [%{code: "invalid_op"}]}
      end

      ref = push(socket, "explode", %{})
      assert_reply ref, :error, %{errors: [%{code: "invalid_op"}]}
      refute_push "op_applied", _
    end

    test "keeps working after the sheet server is killed (P-5)",
         %{socket: socket, sheet: sheet, revenue: revenue, q1: q1} do
      pid = Runtime.whereis(sheet.id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      ref = push(socket, "op", %{"op" => set_cell(revenue, q1, 7)})
      assert_reply ref, :ok, %{version: 2}
      assert_push "op_applied", %{version: 2}
    end
  end

  test "snapshot replies with the current sheet (RT-4 resync)",
       %{alice: alice, sheet: sheet, revenue: revenue, q1: q1} do
    {:ok, _, socket} = join_as(alice, sheet.id)

    ref = push(socket, "op", %{"op" => set_cell(revenue, q1, 9)})
    assert_reply ref, :ok, %{version: 2}

    ref = push(socket, "snapshot", %{})
    assert_reply ref, :ok, %{sheet: %{version: 2, rows: [%{cells: cells}]}}
    assert cells[q1] == 9
  end

  test "participants follow who is viewing (RT-7)", %{alice: alice, sheet: sheet} do
    bob = verified_user_fixture(%{display_name: "Bob"})
    {:ok, _, alice_socket} = join_as(alice, sheet.id)
    assert_participants(alice_socket, ["Alice"])

    {:ok, _, bob_socket} = join_as(bob, sheet.id)
    assert_participants(alice_socket, ["Alice", "Bob"])

    Process.unlink(bob_socket.channel_pid)
    close(bob_socket)
    assert_participants(alice_socket, ["Alice"])
  end

  defp join_as(user, sheet_id) do
    {:ok, socket} = connect_user(user)
    subscribe_and_join(socket, SheetChannel, "sheet:#{sheet_id}")
  end

  # Waits for a `participants` push from `socket`'s channel listing exactly
  # `names`, skipping older pushes (presence diffs arrive asynchronously).
  # Pushes from other channels joined by this test process are left alone.
  defp assert_participants(%{join_ref: join_ref} = socket, names, timeout \\ 1_000) do
    receive do
      %Phoenix.Socket.Message{
        event: "participants",
        join_ref: ^join_ref,
        payload: %{users: users}
      } ->
        if Enum.map(users, & &1.display_name) == names,
          do: :ok,
          else: assert_participants(socket, names, timeout)
    after
      timeout -> flunk("no participants push with #{inspect(names)}")
    end
  end

  defp set_cell(row_id, column_id, value) do
    %{
      "type" => "set_cells",
      "cells" => [%{"row_id" => row_id, "column_id" => column_id, "value" => value}]
    }
  end

  defp q1(sheet) do
    {:ok, column} = Sheets.State.fetch_column_by_name(sheet, "Q1")
    column.id
  end
end
