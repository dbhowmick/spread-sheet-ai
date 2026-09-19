import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :spread_sheet_ai, SpreadSheetAi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 6432,
  database: "spread_sheet_ai_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :spread_sheet_ai, SpreadSheetAiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kYW5CgimhsZ5yguAnQPXU5ObIJSz3W5Q9G/AAB7019TJldHHVUiCNUzbRy8qf91M",
  server: false

# In test we don't send emails
config :spread_sheet_ai, SpreadSheetAi.Mailer, adapter: Swoosh.Adapters.Test

# Oban runs synchronously in tests — jobs execute on the calling process so
# assertions can observe their effects without polling.
config :spread_sheet_ai, Oban, testing: :inline

# Small caps and a short idle timeout so limits and idle stop are cheap to test.
config :spread_sheet_ai, :sheets,
  idle_timeout: 200,
  read_max_rows: 10,
  write_max_cells: 50

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
