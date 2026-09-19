defmodule SpreadSheetAi.Sheets.Server do
  @moduledoc """
  One process per open sheet (P-4). It holds the sheet in memory and applies
  every op to it one at a time (OP-4): engine → Persister transaction →
  replace state → broadcast `{:op_applied, event}` on
  `SpreadSheetAi.Sheets.topic/1`. Nothing is broadcast and the state is
  kept when the engine rejects the op or the write fails (P-2).

  Reads are served from memory. Start and call it through
  `SpreadSheetAi.Sheets.Runtime`, never directly.

  Lifecycle:

    * The sheet is loaded in `handle_continue/2`, so starting a server never
      blocks the DynamicSupervisor.
    * A missing sheet answers the first call with `not_found` and stops.
    * A failed write replies `internal_error` and stops, so the next call
      reloads from Postgres (P-5).
    * After `idle_timeout` with no messages it stops normally.
    * `restart: :temporary`: a crashed server is not restarted, the next
      call starts a fresh one from Postgres.
  """

  use GenServer, restart: :temporary

  require Logger

  alias SpreadSheetAi.Repo
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{ColumnQueries, Engine, Persister, Reads, RowQueries, Runtime}
  alias SpreadSheetAi.Sheets.{SheetQueries, State}

  @doc "Options: `:sheet_id` (required), `:idle_timeout` and `:limits` (default from config)."
  def start_link(opts) do
    sheet_id = Keyword.fetch!(opts, :sheet_id)
    GenServer.start_link(__MODULE__, opts, name: Runtime.via(sheet_id))
  end

  @impl GenServer
  def init(opts) do
    config = Application.fetch_env!(:spread_sheet_ai, :sheets)

    data = %{
      sheet_id: Keyword.fetch!(opts, :sheet_id),
      state: nil,
      idle_timeout: Keyword.get(opts, :idle_timeout, config[:idle_timeout]),
      limits: Keyword.get(opts, :limits, Sheets.limits())
    }

    {:ok, data, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, data) do
    {:noreply, %{data | state: load(data.sheet_id)}, data.idle_timeout}
  end

  @impl GenServer
  def handle_call(_request, _from, %{state: :not_found} = data) do
    error = {:error, :not_found, "sheet not found", %{sheet_id: data.sheet_id}}
    {:stop, {:shutdown, :not_found}, error, data}
  end

  def handle_call({:apply, op, actor, opts}, _from, data) do
    case Engine.apply(data.state, op, data.limits) do
      {:ok, new_state, applied_op, effects} ->
        persist(data, new_state, applied_op, effects, actor, opts)

      {:error, _code, _message, _meta} = error ->
        reply(error, data)
    end
  end

  def handle_call(:snapshot, _from, data), do: reply({:ok, data.state}, data)

  def handle_call(:describe, _from, data), do: reply({:ok, Reads.describe(data.state)}, data)

  def handle_call({:read_rows, opts}, _from, data),
    do: reply(Reads.read_rows(data.state, opts, data.limits.read_max_rows), data)

  def handle_call({:read_cells, labels, columns}, _from, data),
    do: reply(Reads.read_cells(data.state, labels, columns, data.limits.read_max_rows), data)

  def handle_call({:find_rows, query}, _from, data),
    do: reply({:ok, Reads.find_rows(data.state, query, data.limits.read_max_rows)}, data)

  @impl GenServer
  def handle_info(:timeout, data), do: {:stop, :normal, data}
  def handle_info(_message, data), do: {:noreply, data, data.idle_timeout}

  defp persist(data, new_state, applied_op, effects, actor, opts) do
    case Persister.apply(data.sheet_id, new_state.version, effects, applied_op, actor, opts) do
      {:ok, updated_at} ->
        new_state = %{new_state | updated_at: updated_at}

        Phoenix.PubSub.broadcast(
          SpreadSheetAi.PubSub,
          Sheets.topic(data.sheet_id),
          {:op_applied,
           %{
             sheet_id: data.sheet_id,
             version: new_state.version,
             applied_op: applied_op,
             actor: actor,
             client_op_id: Keyword.get(opts, :client_op_id)
           }}
        )

        reply({:ok, new_state.version, applied_op}, %{data | state: new_state})

      {:error, reason} ->
        Logger.error(
          "sheet #{data.sheet_id}: writing version #{new_state.version} failed: #{inspect(reason)}"
        )

        error = {:error, :internal_error, "the change could not be saved", %{}}
        {:stop, {:shutdown, :persist_failed}, error, data}
    end
  end

  defp reply(reply, data), do: {:reply, reply, data, data.idle_timeout}

  defp load(sheet_id) do
    case sheet_id |> SheetQueries.by_id() |> SheetQueries.with_owner() |> Repo.one() do
      nil ->
        :not_found

      sheet ->
        columns = sheet_id |> ColumnQueries.for_sheet() |> Repo.all()
        rows = sheet_id |> RowQueries.for_sheet() |> Repo.all()
        State.load(sheet, columns, rows)
    end
  end
end
