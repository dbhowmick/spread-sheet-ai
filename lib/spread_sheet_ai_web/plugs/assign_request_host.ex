defmodule SpreadSheetAiWeb.Plugs.AssignRequestHost do
  @moduledoc """
  Assigns the request host for Vite HMR URL construction in development.

  Security note: `conn.host` is the request's `Host:` header — fully
  attacker-controllable. In dev the assign flows into a `<script src>`
  in `root.html.heex`, so a DNS-rebinding (or any Host-spoofing)
  attacker who lands a page in a dev's browser could inject scripts
  from an attacker-controlled origin via the Vite URL slot.

  The validation: only assign `request_host` when the host parses as
  an IP address (covers LAN, loopback, Tailscale CGNAT) OR matches a
  small allowlist of safe dev names (`localhost`, `0.0.0.0`, `::1`)
  OR appears in the operator-supplied `:vite_dev_server[:allowed_hosts]`
  config. Anything else falls back to `"localhost"` so HMR still
  works on the local machine but the script src can't be poisoned.

  In prod the `:vite_dev_server` config is unset, so this plug
  becomes a passthrough — `request_host` is never read by the prod
  asset path.
  """

  import Plug.Conn

  @safe_dev_names ~w(localhost 0.0.0.0 ::1)

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:spread_sheet_ai, :vite_dev_server) do
      nil ->
        conn

      vite_config ->
        allowlist = Keyword.get(vite_config, :allowed_hosts, [])
        assign(conn, :request_host, safe_host(conn.host, allowlist))
    end
  end

  defp safe_host(host, allowlist) when is_binary(host) do
    cond do
      host in @safe_dev_names -> host
      host in allowlist -> host
      ip_address?(host) -> host
      true -> "localhost"
    end
  end

  defp safe_host(_, _), do: "localhost"

  defp ip_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
