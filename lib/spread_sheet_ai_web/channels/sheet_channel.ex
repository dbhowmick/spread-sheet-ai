defmodule SpreadSheetAiWeb.SheetChannel do
  @moduledoc """
  `sheet:<sheet_id>` (contract §5): the join snapshot, ops, `op_applied`
  pushes, resync snapshots and participants.

  It subscribes to the sheet's events before taking the join snapshot, so
  an op committed in between is still pushed; the client ignores versions
  it already has (§5.4). Participants come from presence, keyed by user id
  (several tabs are one participant), with each user's `UserRef` as the
  presence meta.
  """

  use SpreadSheetAiWeb, :channel

  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{Actor, Op}
  alias SpreadSheetAiWeb.Api.Errors
  alias SpreadSheetAiWeb.{Presence, SheetJSON}

  intercept ["presence_diff"]

  @impl Phoenix.Channel
  def join("sheet:" <> sheet_id, _params, socket) do
    :ok = Sheets.subscribe(sheet_id)

    case Sheets.snapshot(sheet_id) do
      {:ok, state} ->
        send(self(), :after_join)
        {:ok, %{sheet: SheetJSON.sheet(state)}, assign(socket, :sheet_id, state.id)}

      error ->
        {:error, Errors.from_business(error)}
    end
  end

  @impl Phoenix.Channel
  def handle_in("op", %{"op" => op} = payload, socket) do
    with {:ok, client_op_id} <- client_op_id(Map.get(payload, "client_op_id")),
         {:ok, op} <- Op.parse(op),
         {:ok, version, _applied_op} <-
           Sheets.apply_op(socket.assigns.sheet_id, op, actor(socket), client_op_id: client_op_id) do
      {:reply, {:ok, %{version: version}}, socket}
    else
      error -> {:reply, {:error, Errors.from_business(error)}, socket}
    end
  end

  def handle_in("op", _payload, socket),
    do: reply_error(socket, :invalid_op, "the payload must have an \"op\"")

  def handle_in("snapshot", _payload, socket) do
    case Sheets.snapshot(socket.assigns.sheet_id) do
      {:ok, state} -> {:reply, {:ok, %{sheet: SheetJSON.sheet(state)}}, socket}
      error -> {:reply, {:error, Errors.from_business(error)}, socket}
    end
  end

  def handle_in(event, _payload, socket),
    do: reply_error(socket, :invalid_op, "unknown event #{inspect(event)}")

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    user_ref = SheetJSON.user_ref(socket.assigns.current_user)
    {:ok, _ref} = Presence.track(socket, user_ref.id, %{user: user_ref})
    push_participants(socket)
    {:noreply, socket}
  end

  def handle_info({:op_applied, event}, socket) do
    push(socket, "op_applied", SheetJSON.op_applied(event))
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_out("presence_diff", _diff, socket) do
    push_participants(socket)
    {:noreply, socket}
  end

  defp push_participants(socket),
    do: push(socket, "participants", SheetJSON.participants(Presence.user_refs(socket)))

  defp actor(socket), do: Actor.user(socket.assigns.current_user)

  defp client_op_id(nil), do: {:ok, nil}

  defp client_op_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> invalid_client_op_id(id)
    end
  end

  defp client_op_id(id), do: invalid_client_op_id(id)

  defp invalid_client_op_id(id),
    do:
      {:error, :invalid_op, "client_op_id must be a UUID, got #{inspect(id)}",
       %{field: "client_op_id"}}

  defp reply_error(socket, code, message),
    do: {:reply, {:error, Errors.from_business({:error, code, message, %{}})}, socket}
end
