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
  alias SpreadSheetAi.Repo

  alias SpreadSheetAi.Sheets.{
    Actor,
    ConversationSheet,
    ConversationSheetQueries,
    Engine,
    Op,
    Persister,
    Runtime,
    SheetQueries,
    State
  }

  @type error :: {:error, atom(), String.t(), map()}

  @type summary :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          owner: State.owner(),
          version: pos_integer(),
          row_count: non_neg_integer(),
          column_count: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type access_kind :: :created | :opened | :read | :written

  @type linked_sheet :: %{
          sheet: summary(),
          created_here: boolean(),
          last_access: String.t(),
          first_accessed_at: DateTime.t(),
          last_accessed_at: DateTime.t()
        }

  @access_kinds [:created, :opened, :read, :written]

  @doc """
  Every sheet (all signed-in users see all sheets), most recently updated
  first, with its owner and row and column counts. Read from Postgres; no
  sheet server is started.
  """
  @spec list_sheets() :: [summary()]
  def list_sheets do
    SheetQueries.newest_first()
    |> SheetQueries.with_owner()
    |> SheetQueries.with_counts()
    |> Repo.all()
    |> Enum.map(&summary/1)
  end

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

  @doc """
  Applies a name-based op (`SpreadSheetAi.Sheets.Named`), as the AI tools
  write it, to a sheet as `actor`. The names are resolved inside the sheet
  server, against the state the op is applied to. Returns what
  `apply_op/4` returns.
  """
  @spec apply_named(String.t(), map(), Actor.t(), keyword()) ::
          {:ok, pos_integer(), map()} | error()
  def apply_named(sheet_id, named_op, %Actor{} = actor, opts \\ []) do
    call(sheet_id, {:apply_named, named_op, actor, Keyword.take(opts, [:client_op_id])})
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
  @doc """
  Records that a conversation used a sheet (ST-1). `kind` is how:
  `:created`, `:opened`, `:read` or `:written`. The first link for a pair
  inserts it; later ones update `last_access` and `last_accessed_at`, keep
  `first_accessed_at`, and keep `created_here` once it is true.

  An unknown or malformed conversation or sheet id is `not_found`.
  """
  @spec link(String.t(), String.t(), access_kind()) :: {:ok, ConversationSheet.t()} | error()
  def link(conversation_id, sheet_id, kind) when kind in @access_kinds do
    with {:ok, conversation_id} <- cast_id(conversation_id, :conversation_id),
         {:ok, sheet_id} <- cast_id(sheet_id, :sheet_id) do
      now = DateTime.utc_now(:second)

      %ConversationSheet{}
      |> ConversationSheet.changeset(%{
        conversation_id: conversation_id,
        sheet_id: sheet_id,
        created_here: kind == :created,
        last_access: Atom.to_string(kind),
        first_accessed_at: now,
        last_accessed_at: now
      })
      |> Repo.insert(
        on_conflict: ConversationSheetQueries.relink(),
        conflict_target: [:conversation_id, :sheet_id],
        returning: true
      )
      |> case do
        {:ok, link} -> {:ok, link}
        {:error, changeset} -> link_error(changeset, conversation_id, sheet_id)
      end
    end
  end

  def link(_conversation_id, _sheet_id, kind),
    do: {:error, :invalid_op, "unknown access kind #{inspect(kind)}", %{}}

  @doc """
  The sheets a conversation has used, most recently used first, as
  `LinkedSheet`s (contract §2.9) with each sheet's summary.
  """
  @spec list_links(String.t()) :: [linked_sheet()]
  def list_links(conversation_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} ->
        links =
          ConversationSheetQueries.for_conversation(conversation_id)
          |> ConversationSheetQueries.recent_first()
          |> Repo.all()

        summaries =
          SheetQueries.by_ids(Enum.map(links, & &1.sheet_id))
          |> SheetQueries.with_owner()
          |> SheetQueries.with_counts()
          |> Repo.all()
          |> Map.new(&{&1.sheet.id, summary(&1)})

        Enum.map(links, fn link ->
          %{
            sheet: Map.fetch!(summaries, link.sheet_id),
            created_here: link.created_here,
            last_access: link.last_access,
            first_accessed_at: link.first_accessed_at,
            last_accessed_at: link.last_accessed_at
          }
        end)

      :error ->
        []
    end
  end

  defp summary(%{sheet: sheet, row_count: row_count, column_count: column_count}) do
    %{
      id: sheet.id,
      name: sheet.name,
      owner: State.owner(sheet.owner),
      version: sheet.version,
      row_count: row_count,
      column_count: column_count,
      inserted_at: sheet.inserted_at,
      updated_at: sheet.updated_at
    }
  end

  defp cast_id(id, field) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> not_found(field, id)
    end
  end

  defp link_error(changeset, conversation_id, sheet_id) do
    cond do
      Keyword.has_key?(changeset.errors, :conversation_id) ->
        not_found(:conversation_id, conversation_id)

      Keyword.has_key?(changeset.errors, :sheet_id) ->
        not_found(:sheet_id, sheet_id)

      true ->
        {:error, :internal_error, "could not link the sheet",
         %{errors: inspect(changeset.errors)}}
    end
  end

  defp not_found(:conversation_id, id),
    do: {:error, :not_found, "conversation not found", %{conversation_id: id}}

  defp not_found(:sheet_id, id), do: {:error, :not_found, "sheet not found", %{sheet_id: id}}

  defp call(sheet_id, request) do
    case Ecto.UUID.cast(sheet_id) do
      {:ok, id} -> Runtime.call(id, request)
      :error -> not_found(:sheet_id, sheet_id)
    end
  end
end
