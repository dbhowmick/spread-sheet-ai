defmodule SpreadSheetAiWeb.Presence do
  @moduledoc """
  Tracks who is viewing a sheet or conversation. Used by the sheet and
  conversation channels, and by Sagents to track conversation viewers.

  Viewers are keyed by user id (several tabs are one participant), with the
  user's `UserRef` in the meta under `:user`.
  """

  use Phoenix.Presence,
    otp_app: :spread_sheet_ai,
    pubsub_server: SpreadSheetAi.PubSub

  @doc "The `UserRef`s of everyone viewing a channel's topic, or a topic."
  @spec user_refs(Phoenix.Socket.t() | String.t()) :: [map()]
  def user_refs(socket_or_topic) do
    for {_user_id, %{metas: [%{user: user_ref} | _]}} <- list(socket_or_topic), do: user_ref
  end
end
