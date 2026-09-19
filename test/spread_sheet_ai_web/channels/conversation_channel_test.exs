defmodule SpreadSheetAiWeb.ConversationChannelTest do
  # Agents and sheet servers run under global supervisors and share the
  # sandbox.
  use SpreadSheetAiWeb.ChannelCase, async: false

  # See SpreadSheetAi.Agents.AgentTest.
  @moduletag :capture_log

  import SpreadSheetAi.AuthFixtures
  import SpreadSheetAi.ConversationsFixtures
  import SpreadSheetAi.SheetsFixtures

  alias LangChain.Message.ContentPart
  alias SpreadSheetAi.Accounts.Scope
  alias SpreadSheetAi.Agents.{Chat, Coordinator}
  alias SpreadSheetAi.{Conversations, Sheets}
  alias SpreadSheetAi.Test.ScriptedChatModel
  alias SpreadSheetAiWeb.ConversationChannel

  # Several sockets are joined by the one test process, so pushes are told
  # apart by the socket's join ref.
  defmacrop assert_pushed(socket, event, payload) do
    quote do
      join_ref = unquote(socket).join_ref

      assert_receive %Phoenix.Socket.Message{
                       event: unquote(event),
                       join_ref: ^join_ref,
                       payload: unquote(payload)
                     },
                     2_000
    end
  end

  setup do
    start_supervised!(ScriptedChatModel)
    alice = verified_user_fixture(%{display_name: "Alice"})
    bob = verified_user_fixture(%{display_name: "Bob"})
    conversation = alice |> conversation_fixture() |> stop_agent_on_exit()
    %{alice: alice, bob: bob, conversation: conversation}
  end

  describe "join" do
    test "replies with the conversation, its messages and sheets (CS-6)", %{
      alice: alice,
      conversation: conversation
    } do
      sheet = created_sheet_fixture(%{"name" => "P&L", owner: alice})
      {:ok, _link} = Sheets.link(conversation.id, sheet.id, :created)

      {:ok, _message} =
        Conversations.append_display_message(Scope.for_user(alice), conversation.id, %{
          message_type: "user",
          content_type: "text",
          content: %{"text" => "hi"},
          metadata: %{"sender_user_id" => alice.id, "sender_display_name" => "Alice"}
        })

      assert {:ok, reply, _socket} = join_as(alice, conversation.id)

      assert %{
               conversation: %{id: id, title: nil, created_by: %{display_name: "Alice"}},
               messages: [
                 %{
                   role: "user",
                   content: %{"text" => "hi"},
                   sender: %{display_name: "Alice"}
                 }
               ],
               sheets: [
                 %{
                   sheet: %{id: sheet_id, name: "P&L"},
                   created_here: true,
                   last_access: "created"
                 }
               ],
               status: "not_started"
             } = reply

      assert id == conversation.id
      assert sheet_id == sheet.id
    end

    test "an unknown or malformed conversation is not_found", %{alice: alice} do
      for id <- [Ecto.UUID.generate(), "nope"] do
        assert {:error, %{errors: [%{code: "not_found"}]}} = join_as(alice, id)
      end
    end

    test "participants follow who is viewing (CS-7)", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      {:ok, _, alice_socket} = join_as(alice, conversation.id)
      assert_participants(alice_socket, ["Alice"])

      {:ok, _, bob_socket} = join_as(bob, conversation.id)
      assert_participants(alice_socket, ["Alice", "Bob"])

      Process.unlink(bob_socket.channel_pid)
      close(bob_socket)
      assert_participants(alice_socket, ["Alice"])
    end
  end

  describe "send_message" do
    test "is answered, and every viewer sees it all (CS-2, CS-3, CS-8)", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      ScriptedChatModel.push(["Hello Alice!"])
      {:ok, _, alice_socket} = join_as(alice, conversation.id)
      # Bob joins before any agent runs: his subscription waits for it.
      {:ok, %{status: "not_started"}, bob_socket} = join_as(bob, conversation.id)

      ref = push(alice_socket, "send_message", %{"text" => "hi"})
      # Starting the agent can take longer than the default timeout.
      assert_reply ref, :ok, %{}, 2_000

      assert [
               {"status", %{status: "idle"}},
               {"message",
                %{
                  message: %{
                    role: "user",
                    content: %{"text" => "hi"},
                    sender: %{id: alice_id, display_name: "Alice"}
                  }
                }},
               {"status", %{status: "running"}},
               {"stream_delta", %{text: "Hello Alice!"}},
               {"stream_reset", %{}},
               {"message",
                %{message: %{role: "assistant", content: %{"text" => "Hello Alice!"}}}},
               {"status", %{status: "idle"}}
             ] = alice_socket |> pushes_until_run_end() |> join_deltas()

      assert alice_id == alice.id

      assert_pushed(bob_socket, "message", %{message: %{role: "user", content: %{"text" => "hi"}}})

      assert_pushed(bob_socket, "message", %{
        message: %{role: "assistant", content: %{"text" => "Hello Alice!"}}
      })

      # The model saw who was speaking.
      assert [{messages, _tools}] = ScriptedChatModel.calls()
      assert text(List.last(messages)) == "[Alice]: hi"

      # The title reaches everyone and is stored.
      assert_pushed(alice_socket, "title", %{title: "Scripted title"})
      assert_pushed(bob_socket, "title", %{title: "Scripted title"})
      # The title is stored in the same agent message that broadcast it.
      Chat.status(conversation.id)

      assert {:ok, %{title: "Scripted title"}} =
               Conversations.get_conversation(Scope.for_user(bob), conversation.id)
    end

    test "blank text is refused", %{alice: alice, conversation: conversation} do
      {:ok, _, socket} = join_as(alice, conversation.id)

      ref = push(socket, "send_message", %{"text" => " "})
      assert_reply ref, :error, %{errors: [%{code: "validation_failed", field: "text"}]}
    end

    test "a message sent while the AI is busy is queued (CS-4)", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      ScriptedChatModel.push([blocking_reply("First reply"), "Second reply"])
      {:ok, _, alice_socket} = join_as(alice, conversation.id)
      {:ok, _, bob_socket} = join_as(bob, conversation.id)

      assert_reply push(alice_socket, "send_message", %{"text" => "Plan Q3"}), :ok, %{}, 2_000
      assert_receive {:model_running, model_pid}, 2_000

      assert_reply push(bob_socket, "send_message", %{"text" => "and Q4?"}), :ok, %{}, 2_000

      for socket <- [alice_socket, bob_socket] do
        assert_pushed(socket, "message", %{
          message: %{content: %{"text" => "and Q4?"}, sender: %{display_name: "Bob"}}
        })

        assert_pushed(socket, "message_queued", %{
          sender: %{display_name: "Bob"},
          text: "and Q4?"
        })
      end

      send(model_pid, :release)

      for socket <- [alice_socket, bob_socket], reply <- ["First reply", "Second reply"] do
        assert_pushed(socket, "message", %{message: %{content: %{"text" => ^reply}}})
      end

      assert [_first, {messages, _tools}] = ScriptedChatModel.calls()
      assert text(List.last(messages)) == "[Bob]: and Q4?"
    end
  end

  describe "cancel" do
    test "stops the AI's turn (CS-5)", %{alice: alice, bob: bob, conversation: conversation} do
      ScriptedChatModel.push([blocking_reply("Never sent")])
      {:ok, _, alice_socket} = join_as(alice, conversation.id)
      {:ok, _, bob_socket} = join_as(bob, conversation.id)

      assert_reply push(alice_socket, "send_message", %{"text" => "Plan Q3"}), :ok, %{}, 2_000
      assert_receive {:model_running, _model_pid}, 2_000

      # Anyone in the conversation can stop it.
      assert_reply push(bob_socket, "cancel", %{}), :ok, %{}

      for socket <- [alice_socket, bob_socket] do
        assert_pushed(socket, "status", %{status: "cancelled", error: nil})

        assert_pushed(socket, "message", %{
          message: %{
            role: "assistant",
            content_type: "notification",
            content: %{"stop_reason" => "cancelled"}
          }
        })
      end
    end

    test "with nothing running is not_running", %{alice: alice, conversation: conversation} do
      {:ok, _, socket} = join_as(alice, conversation.id)

      assert_reply push(socket, "cancel", %{}), :error, %{errors: [%{code: "not_running"}]}
    end
  end

  test "history is restored after the agent restarts (CS-6)", %{
    alice: alice,
    conversation: conversation
  } do
    ScriptedChatModel.push(["Hello Alice!", "Welcome back"])
    {:ok, _, socket} = join_as(alice, conversation.id)

    assert_reply push(socket, "send_message", %{"text" => "hi"}), :ok, %{}, 2_000
    pushes_until_run_end(socket)
    # Let the title write land before the agent stops.
    assert_pushed(socket, "title", _)

    assert {:ok, :stopped} = Coordinator.stop_conversation_session(conversation.id)
    Process.unlink(socket.channel_pid)
    close(socket)

    {:ok, reply, socket} = join_as(alice, conversation.id)

    assert %{status: "not_started", messages: [_hi, %{content: %{"text" => "Hello Alice!"}}]} =
             reply

    assert_reply push(socket, "send_message", %{"text" => "again"}), :ok, %{}, 2_000
    pushes_until_run_end(socket)

    # The restarted agent answered with the earlier turn in its context.
    assert [_first, {messages, _tools}] = ScriptedChatModel.calls()

    assert Enum.map(messages, &text/1) |> Enum.take(-3) == [
             "[Alice]: hi",
             "Hello Alice!",
             "[Alice]: again"
           ]
  end

  describe "open_sheet" do
    test "links the sheet and tells every viewer, without focusing it (ST-2)", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      sheet = created_sheet_fixture(%{"name" => "P&L", owner: bob})
      {:ok, _, alice_socket} = join_as(alice, conversation.id)
      {:ok, _, bob_socket} = join_as(bob, conversation.id)

      ref = push(alice_socket, "open_sheet", %{"sheet_id" => sheet.id})

      assert_reply ref, :ok, %{
        sheet: %{sheet: %{id: sheet_id, row_count: 0}, created_here: false, last_access: "opened"}
      }

      assert sheet_id == sheet.id

      for socket <- [alice_socket, bob_socket] do
        assert_pushed(socket, "sheets", %{sheets: [%{sheet: %{id: ^sheet_id}}]})
      end

      refute_receive %Phoenix.Socket.Message{event: "focus_sheet"}
    end

    test "an unknown sheet is not_found", %{alice: alice, conversation: conversation} do
      {:ok, _, socket} = join_as(alice, conversation.id)

      ref = push(socket, "open_sheet", %{"sheet_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{errors: [%{code: "not_found"}]}

      ref = push(socket, "open_sheet", %{})
      assert_reply ref, :error, %{errors: [%{code: "invalid_op"}]}
    end
  end

  test "a focus_sheet event reaches the conversation's viewers (UI-4)", %{
    alice: alice,
    conversation: conversation
  } do
    {:ok, _, socket} = join_as(alice, conversation.id)
    sheet_id = Ecto.UUID.generate()

    :ok = Conversations.broadcast_event(conversation.id, {:focus_sheet, sheet_id, :written})

    assert_pushed(socket, "focus_sheet", %{sheet_id: ^sheet_id, reason: "written"})
  end

  test "an unknown event is invalid_op", %{alice: alice, conversation: conversation} do
    {:ok, _, socket} = join_as(alice, conversation.id)

    assert_reply push(socket, "delete_everything", %{}), :error, %{
      errors: [%{code: "invalid_op"}]
    }
  end

  defp join_as(user, conversation_id) do
    {:ok, socket} = connect_user(user)
    subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation_id}")
  end

  # A model reply that waits for the test to send `:release`, so the test
  # can act while the AI is busy.
  defp blocking_reply(text) do
    test_pid = self()

    fn _messages, _tools ->
      send(test_pid, {:model_running, self()})

      receive do
        :release -> text
      end
    end
  end

  # The pushes to `socket` in order, up to the `idle` status that ends a run
  # (one that comes after `running`). `participants` and `title` pushes,
  # which may arrive at any time, are left out.
  defp pushes_until_run_end(%{join_ref: join_ref} = socket, acc \\ []) do
    receive do
      %Phoenix.Socket.Message{join_ref: ^join_ref, event: event, payload: payload}
      when event not in ["participants", "title"] ->
        acc = [{event, payload} | acc]

        if run_ended?(acc),
          do: Enum.reverse(acc),
          else: pushes_until_run_end(socket, acc)
    after
      2_000 -> flunk("the run didn't end; pushes: #{inspect(Enum.reverse(acc))}")
    end
  end

  defp run_ended?([{"status", %{status: "idle"}} | earlier]),
    do: Enum.any?(earlier, &match?({"status", %{status: "running"}}, &1))

  defp run_ended?(_pushes), do: false

  # Streamed text arrives in several chunks; joins consecutive ones.
  defp join_deltas(pushes) do
    pushes
    |> Enum.chunk_by(&match?({"stream_delta", _}, &1))
    |> Enum.flat_map(fn
      [{"stream_delta", _} | _] = deltas ->
        [{"stream_delta", %{text: Enum.map_join(deltas, fn {_, %{text: t}} -> t end)}}]

      other ->
        other
    end)
  end

  # Waits for a `participants` push from `socket`'s channel listing exactly
  # `names`, skipping older pushes (presence diffs arrive asynchronously).
  defp assert_participants(%{join_ref: join_ref} = socket, names) do
    receive do
      %Phoenix.Socket.Message{
        event: "participants",
        join_ref: ^join_ref,
        payload: %{users: users}
      } ->
        if Enum.map(users, & &1.display_name) == names,
          do: :ok,
          else: assert_participants(socket, names)
    after
      1_000 -> flunk("no participants push with #{inspect(names)}")
    end
  end

  defp text(message), do: ContentPart.parts_to_string(message.content)
end
