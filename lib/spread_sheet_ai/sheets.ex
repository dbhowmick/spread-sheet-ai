defmodule SpreadSheetAi.Sheets do
  @moduledoc """
  The sheets context: create sheets, apply ops and read sheets. It is the
  one API used by the sheet channel, REST and the AI tools.

  Every change to an existing sheet goes through that sheet's server
  (`SpreadSheetAi.Sheets.Server`), which applies ops one at a time, writes
  each to Postgres before broadcasting it, and serves reads from memory.
  Creating a sheet skips the server: it is written in one transaction, and
  the server starts on first use.

  Errors are `{:error, code, message, meta}` with a contract §8 code.
  """

  require Logger

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.Sheets.{Actor, Engine, Op, Persister, Runtime, State}

  @type error :: {:error, atom(), String.t(), map()}

  @doc """
  Creates a sheet from `parse_create` params (contract §3 `POST /api/sheets`
  plus optional `rows`) at version 1, owned by `owner`. The change log
  records `actor`, which defaults to the owner.
  """
  @spec create_sheet(map(), User.t(), Actor.t() | nil) :: {:ok, State.t()} | error()
  def create_sheet(params, %User{} = owner, actor \\ nil) do
    actor = actor || Actor.user(owner)

    with {:ok, op} <- Op.parse_create(params),
         {:ok, state, applied_op, effects} <- Engine.create(op, owner.id, limits()) do
      case Persister.create(effects, applied_op, actor) do
        {:ok, timestamps} ->
          {:ok, %{state | owner: State.owner(owner)} |> Map.merge(timestamps)}

        {:error, reason} ->
          Logger.error("creating sheet #{state.id} failed: #{inspect(reason)}")
          {:error, :internal_error, "the sheet could not be saved", %{}}
      end
    end
  end

  @doc """
  Applies a parsed op (`SpreadSheetAi.Sheets.Op.parse/1`) to a sheet as
  `actor`. Options: `:client_op_id`. Returns the new version and the
  `AppliedOp`.
  """
  @spec apply_op(String.t(), Op.t(), Actor.t(), keyword()) ::
          {:ok, pos_integer(), map()} | error()
  def apply_op(sheet_id, op, %Actor{} = actor, opts \\ []) do
    call(sheet_id, {:apply, op, actor, Keyword.take(opts, [:client_op_id])})
  end

  @doc "The sheet's full in-memory state."
  @spec snapshot(String.t()) :: {:ok, State.t()} | error()
  def snapshot(sheet_id), do: call(sheet_id, :snapshot)

  @doc "The sheet's structure. See `SpreadSheetAi.Sheets.Reads.describe/1`."
  @spec describe(String.t()) :: {:ok, map()} | error()
  def describe(sheet_id), do: call(sheet_id, :describe)

  @doc "A page of rows. See `SpreadSheetAi.Sheets.Reads.read_rows/3`."
  @spec read_rows(String.t(), keyword()) :: {:ok, map()} | error()
  def read_rows(sheet_id, opts \\ []), do: call(sheet_id, {:read_rows, opts})

  @doc "Cells by row label × column name. See `SpreadSheetAi.Sheets.Reads.read_cells/4`."
  @spec read_cells(String.t(), [String.t()], [String.t()]) :: {:ok, map()} | error()
  def read_cells(sheet_id, labels, columns), do: call(sheet_id, {:read_cells, labels, columns})

  @doc "Rows whose label contains `query`. See `SpreadSheetAi.Sheets.Reads.find_rows/3`."
  @spec find_rows(String.t(), String.t()) :: {:ok, map()} | error()
  def find_rows(sheet_id, query), do: call(sheet_id, {:find_rows, query})

  @doc "The PubSub topic a sheet's `{:op_applied, event}` messages go to."
  @spec topic(String.t()) :: String.t()
  def topic(sheet_id), do: "sheet_events:#{sheet_id}"

  @doc """
  Subscribes the caller to a sheet's applied ops. Each arrives as
  `{:op_applied, %{sheet_id, version, applied_op, actor, client_op_id}}`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(sheet_id), do: Phoenix.PubSub.subscribe(SpreadSheetAi.PubSub, topic(sheet_id))

  @doc "The op size caps (`:write_max_cells`) and the read cap (`:read_max_rows`), from config."
  @spec limits() :: %{write_max_cells: pos_integer(), read_max_rows: pos_integer()}
  def limits do
    config = Application.fetch_env!(:spread_sheet_ai, :sheets)
    %{write_max_cells: config[:write_max_cells], read_max_rows: config[:read_max_rows]}
  end

  # A malformed id can't name a sheet, so no server is started for it.
  defp call(sheet_id, request) do
    case Ecto.UUID.cast(sheet_id) do
      {:ok, id} -> Runtime.call(id, request)
      :error -> {:error, :not_found, "sheet not found", %{sheet_id: sheet_id}}
    end
  end
end
