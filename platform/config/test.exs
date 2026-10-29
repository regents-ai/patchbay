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
  hostname: System.get_env("PATCHBAY_DB_HOST", "127.0.0.1"),
  database: "patchbay#{System.get_env("MIX_TEST_PARTITION")}_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Keep parallel worktrees within the local PostgreSQL connection budget.
  pool_size: 8

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :patchbay, PatchbayWeb.Endpoint,
  url: [host: "127.0.0.1", port: browser_port],
  http: [ip: {127, 0, 0, 1}, port: browser_port],
  check_origin: ["http://127.0.0.1:#{browser_port}", "http://open.patchbay.test:#{browser_port}"],
  secret_key_base: "veQzbAXuIb79+jLk5QWx2Jq4Gy/5WzZbQRfCk77MHXxP2IUiKWLI5vDOixz/wQlP",
  server: false

# The open address (PatchbayWeb.SiteEdition). A test reaches it by setting a
# request's host to this.
config :patchbay, :open_host, "open.patchbay.test"

# In test we don't send emails
config :patchbay, Patchbay.Mailer, adapter: Swoosh.Adapters.Test

config :patchbay, :load_sites_at_boot, false
config :patchbay, Oban, testing: :manual

# Tests name sites under the endings reserved for testing and examples, which
# the Public Suffix List leaves out; here they count as real endings.
config :domainatrex, custom_suffixes: ["example", "invalid", "test"]

# A closed incident beside the live ones, so a test reads both kinds.
config :patchbay, :incident_files, ["priv/incidents/*.md", "test/support/incidents/*.md"]

# Every test request comes from one address, so the suite would spend a
# visitor's share of reads, and of signed agent requests, many times over.
config :patchbay, :reads_per_minute, 1_000_000
config :patchbay, :signed_per_minute, 1_000_000
config :patchbay, :chatgpt_account_per_minute, 1_000_000

# The same holds for posts with nobody signed in, which each address counts too.
config :patchbay, :forum_address_reports_per_hour, 1_000_000
config :patchbay, :forum_address_replies_per_hour, 1_000_000

# The payment tests act for a few wallets many times over; the share itself
# is proved with a small limit set by its own test.
config :patchbay, :payments_per_minute, 1_000_000

# The payments lab at /dev/lab/payments: a stand-in wallet app and payment
# service over a copy of Base on this machine (see `PatchbayDev.PaymentsLab`).
config :patchbay, :payments_lab, %{rpc_url: "http://127.0.0.1:58611"}

# Every request a test sends through Req without a stub that leaves this machine is
# recorded and refused, and fails the run (PatchbayTest.Offline).
config :req, default_options: [adapter: PatchbayTest.Offline]

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

# A site check's outside lists (the MCP Registry, GitHub, npm) answer from
# the tests, never the internet.
config :patchbay, :site_scan_req_options, plug: Patchbay.OutsideLists

# An MCP events callback's challenge is answered by the test itself
# (`PatchbayWeb.CallbackStandIn`), never sent to an address.
config :patchbay, Patchbay.Forum.EventSubscription, webhooks: PatchbayWeb.CallbackStandIn

# The SIWA service answers signed agent requests from each test's own stub
# (`PatchbayWeb.SignedAgent.stub_siwa/0`), never the internet.
config :regent_agents, :req_options, plug: {Req.Test, RegentAgents.Broker}
config :regent_agents, siwa: [url: "https://siwa.test", audience: "patchbay"]

# Jev answers from each test's own stand-in (`Patchbay.JevStandIn`), never
# the internet.
config :patchbay, :jev_req_options, plug: {Req.Test, Patchbay.Forum.Jev}

# The weekly answer check asks each test's own stand-in, never the internet.
config :patchbay, :answer_watch_req_options, plug: {Req.Test, Patchbay.AnswerWatch}

# IndexNow is answered by the test itself (Patchbay.IndexNow).
config :patchbay, :indexnow_req, plug: {Req.Test, Patchbay.IndexNow}

# A view the Wallet Bench test makes slow on purpose is cancelled after one
# second instead of five.
config :patchbay, Patchbay.WalletBench.Board, statement_timeout: 1_000
