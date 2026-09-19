defmodule SpreadSheetAi.Sheets.Runtime do
  @moduledoc """
  Starts sheet servers on demand and calls them. Servers are registered in
  `SpreadSheetAi.Sheets.Registry` by sheet id and supervised by
  `SpreadSheetAi.Sheets.ServerSupervisor`.

  `call/2` retries once when the server stopped before handling the call
  (an idle stop or a stop after a failed write racing with the call). A
  server that stopped before handling a call never applied it, so the retry
  can't apply an op twice. Any other exit is `internal_error`.
  """

  require Logger

  alias SpreadSheetAi.Sheets.Server

  @registry SpreadSheetAi.Sheets.Registry
  @supervisor SpreadSheetAi.Sheets.ServerSupervisor
  @call_timeout :timer.seconds(15)

  @doc "The registered name of a sheet's server."
  def via(sheet_id), do: {:via, Registry, {@registry, sheet_id}}

  @doc """
  The pid of a sheet's running server, or `nil`. This goes through the
  `:via` name, which skips a server that has exited but is still
  registered (the Registry unregisters it asynchronously).
  """
  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(sheet_id), do: GenServer.whereis(via(sheet_id))

  @doc "Returns the sheet's server, starting it if needed."
  @spec ensure_started(Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(sheet_id) do
    case whereis(sheet_id) do
      nil -> start(sheet_id)
      pid -> {:ok, pid}
    end
  end

  @doc "Calls the sheet's server, starting it if needed."
  @spec call(Ecto.UUID.t(), term()) :: term()
  def call(sheet_id, request), do: call(sheet_id, request, 1)

  defp call(sheet_id, request, retries) do
    case ensure_started(sheet_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, request, @call_timeout)
        catch
          :exit, {reason, _call} -> exited(sheet_id, request, reason, retries)
        end

      {:error, reason} ->
        internal_error(sheet_id, reason)
    end
  end

  defp exited(sheet_id, _request, {:shutdown, :not_found}, _retries),
    do: {:error, :not_found, "sheet not found", %{sheet_id: sheet_id}}

  defp exited(sheet_id, request, reason, retries) when retries > 0 do
    if stopped_before_handling?(reason),
      do: call(sheet_id, request, retries - 1),
      else: internal_error(sheet_id, reason)
  end

  defp exited(sheet_id, _request, reason, _retries), do: internal_error(sheet_id, reason)

  defp stopped_before_handling?(:noproc), do: true
  defp stopped_before_handling?(:normal), do: true
  defp stopped_before_handling?({:shutdown, _reason}), do: true
  defp stopped_before_handling?(_reason), do: false

  defp start(sheet_id) do
    case DynamicSupervisor.start_child(@supervisor, {Server, sheet_id: sheet_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp internal_error(sheet_id, reason) do
    Logger.error("sheet #{sheet_id}: server call failed: #{inspect(reason)}")
    {:error, :internal_error, "something went wrong, reload the sheet", %{}}
  end
end
