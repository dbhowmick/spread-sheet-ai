defmodule SpreadSheetAi.Repo do
  use Ecto.Repo,
    otp_app: :spread_sheet_ai,
    adapter: Ecto.Adapters.Postgres
end
