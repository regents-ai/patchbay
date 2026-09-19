import Config
browser_port = String.to_integer(System.get_env("PORT", "4002"))

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :patchbay, Patchbay.Repo,
  username: System.get_env("PATCHBAY_DB_USERNAME", System.get_env("USER", "postgres")),
  password: System.get_env("PATCHBAY_DB_PASSWORD"),
  hostname: System.get_env("PATCHBAY_DB_HOST", "localhost"),
  database: "patchbay_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Keep parallel worktrees within the local PostgreSQL connection budget.
  pool_size: 8

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :patchbay, PatchbayWeb.Endpoint,
  url: [host: "127.0.0.1", port: browser_port],
  http: [ip: {127, 0, 0, 1}, port: browser_port],
  check_origin: ["http://127.0.0.1:#{browser_port}"],
  secret_key_base: "veQzbAXuIb79+jLk5QWx2Jq4Gy/5WzZbQRfCk77MHXxP2IUiKWLI5vDOixz/wQlP",
  server: false

# In test we don't send emails
config :patchbay, Patchbay.Mailer, adapter: Swoosh.Adapters.Test

# The repair worker is started by the tests that exercise it, so no test is
# racing a loop it did not ask for. The notification worker the same: tests
# run its pass directly.
config :patchbay, start_patchbay_agent: false
config :patchbay, :sync_webmcp_catalog, false
config :patchbay, :notification_fanout, false
config :patchbay, :jev_reader, false

# Every test request comes from one address, so the suite would spend a
# visitor's share of reads many times over.
config :patchbay, :reads_per_minute, 1_000_000

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
