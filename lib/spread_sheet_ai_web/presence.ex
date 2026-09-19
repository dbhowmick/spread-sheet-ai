defmodule SpreadSheetAiWeb.Presence do
  @moduledoc """
  Tracks who is viewing a sheet or conversation. Used by the sheet and
  conversation channels, and by Sagents to track conversation viewers.
  """

  use Phoenix.Presence,
    otp_app: :spread_sheet_ai,
    pubsub_server: SpreadSheetAi.PubSub
end
