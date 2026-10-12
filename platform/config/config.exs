# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Codepoints bound stored length; one grapheme can contain unbounded combining
# marks. Keep the stricter byte validators on public report and reply fields.
config :ash, default_string_length_count: :codepoints

config :regent_identity, repo: Patchbay.Repo, ash_domains: [RegentIdentity]

# Regent Credits: one prepaid balance per Privy account, shared by every Regent
# site. Credits are the private currency XRC, kept to the millionth. The ledger
# lives in the shared `regent_credits` schema, which Regents migrates; Patchbay
# reads and writes it through its own Repo, so an Offer bid and its Credits
# commit together. Admins come from REGENT_CREDITS_ADMINS at runtime. Balance
# changes from every site reach Patchbay's PubSub, and a purchase Patchbay
# credits is told to `Patchbay.Credits.Credited`.
config :ex_money,
  custom_currencies: [{:XRC, name: "Credits", digits: 6}],
  auto_start_exchange_rate_service: false

config :regent_credits,
  repo: Patchbay.Repo,
  pubsub: Patchbay.PubSub,
  ash_domains: [RegentCredits],
  admins: [],
  chain_client: Patchbay.ChainClient,
  on_credited: Patchbay.Credits.Credited,
  chains: %{
    base: %{chain_id: 8453, name: "Base", rpc_url: "https://mainnet.base.org"},
    ethereum: %{chain_id: 1, name: "Ethereum", rpc_url: "https://ethereum-rpc.publicnode.com"}
  }

# The node the server reads each chain through, by chain id, to check Credits
# purchases. A wallet adds a chain with its public `rpc_url` above; the server
# may read through a private node instead (config/runtime.exs), and that
# address never reaches the browser.
config :patchbay, :chain_nodes, %{
  8453 => "https://mainnet.base.org",
  1 => "https://ethereum-rpc.publicnode.com"
}

# Jev, TypeSafe's classifier, and the model that drafts a tool's arguments,
# both on OpenRouter. The key is read at boot in config/runtime.exs.
config :patchbay, :openrouter,
  jev_url: "https://openrouter.ai/api/alpha/decisions",
  jev_model: "~typesafe/jev-latest",
  drafter_url: "https://openrouter.ai/api/v1/chat/completions",
  drafter_model: "openai/gpt-5.6-terra"

# Agents paired with a person's Regent account, shared by every Regent site. A
# check-in names the person's Patchbay profile; the SIWA sign-in server is set
# in config/runtime.exs.
config :regent_agents,
  repo: Patchbay.Repo,
  pubsub: Patchbay.PubSub,
  account: {Patchbay.Identity, :paired_account},
  ash_domains: [RegentAgents]

# Background jobs, in Patchbay's own schema (set in config/runtime.exs). Each
# queue is added here with the jobs it runs: a run of an assist, four at once
# (`Patchbay.Assist.Run`'s `:work`); closing runs whose work was lost; a fee
# forwarded to the staking contract, and the escrow's 10% pushed there, one at
# a time so the operator wallet sends in order (`:forward_fee`, and
# `Patchbay.Forum.Report`'s `:push_escrow_revenue`); Jev's reading of a
# priority report (`:read_by_jev`); the screening of an Offer's wording
# (`Patchbay.Offers.Review`'s `:screen`); board events posted to MCP events
# subscribers (`Patchbay.Forum.EventSubscription`'s `:deliver`); deciding an
# Offer bid window and ending an Offer at its expiry (`Patchbay.Offers.BidWindow`'s
# `:settle` and `Patchbay.Offers.Placement`'s `:expire`); checking Credits
# purchases on chain (`regent_credits`); and a site's check
# (`Patchbay.Forum.SiteCheck`'s `:run`) and the picture for its card
# (`Patchbay.Forum.Site`'s `:take_picture`), each on its own queue so slow
# sites wait only on each other.
config :patchbay, Oban,
  repo: Patchbay.Repo,
  queues: [
    assist: 4,
    lost_runs: 1,
    fees: 1,
    jev: 2,
    offers_review: 2,
    offers_settlement: 4,
    webhooks: 10,
    regent_credits: 3,
    site_checks: 2,
    site_pictures: 1
  ],
  # AshOban adds each trigger's minute sweep here.
  cron: [crontab: []],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {10, :minutes}]

# Jobs are internal bookkeeping on resources closed to public reads, and skip
# authorization as Patchbay's other internal reads and writes do.
config :ash_oban, pro?: false, authorize?: false

config :patchbay,
  ecto_repos: [Patchbay.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  ash_domains: [
    Patchbay.Assist,
    Patchbay.Identity,
    Patchbay.Forum,
    Patchbay.Offers,
    Patchbay.CreditsHelp,
    Patchbay.Patchbay,
    Patchbay.WalletBench
  ]

# The only tools the repair assistant calls on a customer's behalf, by site
# host: ones Patchbay has read the code of and found only read. Each call is
# still refused unless the site itself marks the tool read-only and not
# destructive. Every other tool is suggested, never called. Add a tool here
# only after reading what it does; see `Patchbay.Assist.ReadOnlyTools`.
#
# patchbay.help: the public reads of Patchbay's own hosted tools
# (`PatchbayWeb.MCP.Tools`). Each answers from a database read and writes
# nothing, needs no session and no wallet.
config :patchbay, :assist_read_only_tools, %{
  "patchbay.help" => ~w(get_patchbay_help get_webmcp_guide list_sites search_threads get_thread
       get_tool_history get_agent_profile)
}

# Paid actions, through the Regents payments library shared by every Regent
# site: a tip to an agent profile, a paid priority report and a paid assist.
# The payment records live in the shared `regent_payments` schema, which
# Regents migrates; Patchbay reads and writes only its own rows.
#
# `payment_chain` is the network a page's wallet signs a payment on, as the
# wallet is told it: Base, with Base's public endpoint for a wallet that has
# to add the network. Only the wallet uses that endpoint.
config :regent_payments,
  repo: Patchbay.Repo,
  site: "patchbay",
  ash_domains: [RegentPayments],
  offers: [
    Patchbay.Payments.AgentTip,
    Patchbay.Payments.SpecialPost,
    Patchbay.Payments.JevAssist
  ],
  payment_chain: %{name: "Base", rpc_url: "https://mainnet.base.org"},
  wallet_proof: [name: "Patchbay", version: "1", endpoint: PatchbayWeb.Endpoint]

# Configure the endpoint
# A sign-in lasts 30 days: the session cookie expires then, and
# `PatchbayWeb.Plugs.CurrentProfile` reads a sign-in older than this as signed out.
config :patchbay, :sign_in_lifetime_seconds, 30 * 24 * 60 * 60

config :patchbay, PatchbayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PatchbayWeb.ErrorHTML, json: PatchbayWeb.ErrorJSON, md: PatchbayWeb.ErrorMD],
    layout: false
  ],
  pubsub_server: Patchbay.PubSub,
  live_view: [signing_salt: "NjIe8lvc"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :patchbay, Patchbay.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
#
# The Privy bridge is a bundle of its own rather than part of `app.js`: it
# carries a whole wallet SDK, and nobody who never asks to sign in should pay
# for it. The page fetches it by address on the first sign-in click, so it is
# built as a module.
config :esbuild,
  version: "0.25.4",
  patchbay: [
    args:
      ~w(js/app.ts js/theme.ts js/runtime.ts --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ],
  patchbay_crown: [
    args:
      ~w(js/crown_island.ts --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ],
  patchbay_privy: [
    args:
      ~w(js/privy_bridge.tsx --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :error_type]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Every page also answers `Accept: text/markdown` with a markdown document.
# The only `.eex` templates in this application are those markdown ones.
config :phoenix_template, :template_engines, eex: PatchbayWeb.MarkdownEngine
config :phoenix, :filter_parameters, ["password", "payment_signature"]

# Brandfetch's logo service identifies the site by this public client ID;
# it is part of every logo address on the page.
config :patchbay, :brandfetch_client_id, "1idVbUBAKPkFD9MEPEc"

# The screenshot machine: a separate Fly app on the private network that
# runs the browser for site cards and holds no keys.
config :patchbay, :shots_url, "http://patchbay-shots.flycast"

# Rate limits key on the direct peer. Production turns on Fly's client header.
config :patchbay, :behind_fly_proxy, false

# Sites are registrable domains, read from the Public Suffix List bundled with
# domainatrex. Builds use that copy and never fetch the list.
config :domainatrex, fetch_latest: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
