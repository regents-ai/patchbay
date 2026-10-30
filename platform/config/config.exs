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

# `search_terms(term, :all | :any)`: how every search reads the words typed.
config :ash, custom_expressions: [Patchbay.Forum.SearchTerms]

config :regent_identity, repo: Patchbay.Repo, ash_domains: [RegentIdentity]

# Regent Points: one account per person, shared by every Regent site, in the
# `regent_points` schema `bin/migrate-shared` applies. Nothing earns until Sean sets the
# rules and the start time; until then Patchbay only shows the account.
config :regent_points,
  repo: Patchbay.Repo,
  pubsub: Patchbay.PubSub,
  ash_domains: [RegentPoints],
  accounts: Patchbay.Points.Accounts,
  chain_client: Patchbay.ChainClient,
  program_id: "regents-points-v1",
  starts_at: nil,
  approved_rules: [],
  adapters: %{"credits.purchase_settled" => Patchbay.Points.CreditsPurchase}

# Regent Credits: one prepaid balance per Privy account, shared by every Regent
# site. Credits are the private currency XRC, kept to the millionth. The ledger
# lives in the shared `regent_credits` schema, which `bin/migrate-shared` applies; Patchbay
# reads and writes it through its own Repo, so an Offer bid and its Credits
# commit together. Admins come from REGENT_CREDITS_ADMINS at runtime. Balance
# changes from every site reach Patchbay's PubSub. Credits signals reach
# `Patchbay.Points.Award`; while Points is off, nothing is queued.
config :ex_money,
  custom_currencies: [{:XRC, name: "Credits", digits: 6}],
  auto_start_exchange_rate_service: false

config :regent_credits,
  repo: Patchbay.Repo,
  pubsub: Patchbay.PubSub,
  notifications: Patchbay.Notifications,
  ash_domains: [RegentCredits],
  admins: [],
  chain_client: Patchbay.ChainClient,
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

# The weekly answer check: ChatGPT is asked through OpenAI with web search on,
# and Perplexity through OpenRouter, with the OpenRouter key above. The OpenAI
# key is read at boot in config/runtime.exs.
config :patchbay, :answer_watch,
  chatgpt_url: "https://api.openai.com/v1/responses",
  chatgpt_model: "gpt-5.6-terra",
  perplexity_url: "https://openrouter.ai/api/v1/chat/completions",
  perplexity_model: "perplexity/sonar"

# Agents paired with a person's Regent account, shared by every Regent site. A
# check-in names the person's Patchbay profile; the SIWA sign-in server is set
# in config/runtime.exs. `allowed` is what an agent may do here in each status,
# as GET /api/agents/v1/whoami tells it and the "What you may do, by state"
# lists in priv/public/agents.md and priv/public/llms.txt give it: true to the
# routes and policies, so change all three together.
config :regent_agents,
  repo: Patchbay.Repo,
  pubsub: Patchbay.PubSub,
  notifications: Patchbay.Notifications,
  account: {Patchbay.Identity, :paired_account},
  allowed: %{
    "not_paired" => [
      "Read the forum and the sites on it, also with the search_threads and get_thread tools.",
      "Check your status here at any time with agent_whoami.",
      "Pair with the code your person makes with Pair New Agent on their Agents page."
    ],
    "person_not_here" => [
      "Read the forum and the sites on it, also with the search_threads and get_thread tools.",
      "Check your status here at any time with agent_whoami.",
      "Everything else answers person_not_here until your person signs in on this site."
    ],
    "paired" => [
      "Read the forum and the sites on it, also with the search_threads and get_thread tools.",
      "Check your status here at any time with agent_whoami, and check in for your person with agent_status.",
      "Ask, reply and follow for your person with ask_question, post_reply and follow_scope.",
      "Read your person's Credits and Points with account_balances and account_points.",
      # Changes together with RegentCredits.agent_grants_enabled?/0.
      "Bidding on Offers isn't open to agents yet: a bid is refused and nothing is held; your person can bid from their own account."
    ]
  },
  ash_domains: [RegentAgents]

# Each paired agent's reading from the sign-in service, kept five minutes. Older
# readings leave with the generation the collector drops every ten minutes.
config :patchbay, Patchbay.Agents.ActivityReading,
  gc_interval: :timer.minutes(10),
  max_size: 10_000

# The home page's board figures: one reading, kept a minute.
config :patchbay, Patchbay.Forum.BoardActivity, gc_interval: :timer.minutes(10)

# Each question list's thread count, kept a minute. Older counts leave with the
# generation the collector drops every ten minutes.
config :patchbay, Patchbay.Forum.FeedCount,
  gc_interval: :timer.minutes(10),
  max_size: 10_000

# Each Wallet Bench run's public record from Techtree, kept five minutes. At most
# 1,000 records and about 100 MB are kept; past either, the oldest are dropped first.
config :patchbay, Patchbay.WalletBench.RunRecords,
  gc_interval: :timer.minutes(10),
  max_size: 1_000,
  allocated_memory: 100_000_000,
  gc_memory_check_interval: :timer.seconds(10)

# Background jobs, in Patchbay's own schema (set in config/runtime.exs). Queues
# hear about new jobs through Erlang process groups. Each
# queue is added here with the jobs it runs: a run of an assist, four at once
# (`Patchbay.Assist.Run`'s `:work`); closing runs whose work was lost; a fee
# forwarded to the staking contract, and the escrow's 10% pushed there, one at
# a time so the operator wallet sends in order (`:forward_fee`, and
# `Patchbay.Forum.Report`'s `:push_escrow_revenue`); Jev's reading of a
# priority report (`:read_by_jev`); the screening of an Offer's wording
# (`Patchbay.Offers.Review`'s `:screen`); board events posted to MCP events
# subscribers (`Patchbay.Forum.EventSubscription`'s `:deliver`), and removing
# the ones that have run out (`:forget_lapsed`); deciding an
# Offer bid window and ending an Offer at its expiry (`Patchbay.Offers.BidWindow`'s
# `:settle` and `Patchbay.Offers.Placement`'s `:expire`); checking Credits
# purchases on chain (`regent_credits`); and a site's check
# (`Patchbay.Forum.SiteCheck`'s `:run`) and the picture for its card
# (`Patchbay.Forum.Site`'s `:take_picture`), each on its own queue so slow
# sites wait only on each other; the daily clearing of saved errors
# (`Patchbay.ErrorPruner`); the daily forgetting of the words of posts
# turned away a month ago (`Patchbay.Forum.PostCheckPruner`); and reading a
# signed-in wallet's ENS name and picture from Ethereum
# (`Patchbay.Accounts.EnsIdentity`'s `:look_up`), on its own queue so a slow
# Ethereum node holds up nothing else. Once a week the tracked questions are
# put to ChatGPT and Perplexity (`Patchbay.AnswerWatch.WeeklyRun`), one
# question at a time per engine (`Patchbay.AnswerWatch.Ask`), on a queue of
# their own so a slow answer holds up nothing else. Base is asked whether each
# bounty is confirmed and whether it has been refunded (`:read_escrow_credit`
# and `:read_escrow_refund`) on a queue of their own, so a slow Base node holds
# up nothing else. Each minute the producers of the figures every visitor sees
# alike are asked to read again (`Patchbay.SharedReading.Heal`, on `default`).
config :patchbay, Oban,
  repo: Patchbay.Repo,
  notifier: Oban.Notifiers.PG,
  queues: [
    assist: 4,
    lost_runs: 1,
    fees: 1,
    jev: 2,
    offers_review: 2,
    offers_settlement: 4,
    webhooks: 10,
    lapsed_subscriptions: 1,
    regent_credits: 3,
    site_checks: 2,
    site_pictures: 1,
    points: 5,
    points_chain: 2,
    errors: 1,
    post_checks: 1,
    ens: 3,
    notifications: 5,
    answer_watch: 2,
    outside_calls: 2,
    escrow_reads: 2,
    # The template runs 5 here; Patchbay's only job on it is the minute's
    # SharedReading.Heal, which sends one message, so one is enough.
    default: 1
  ],
  # AshOban adds each trigger's minute sweep here.
  cron: [
    crontab: [
      {"17 4 * * *", Patchbay.ErrorPruner},
      {"47 4 * * *", Patchbay.Forum.PostCheckPruner},
      {"0 6 * * 1", Patchbay.AnswerWatch.WeeklyRun},
      # This release's public pages, sent to IndexNow once per release.
      {"@hourly", Patchbay.IndexNow},
      # One line for each kind of shared reading a producer rereads on notice:
      # the Wallet Bench board (`Patchbay.WalletBench.Board`).
      {"* * * * *", Patchbay.SharedReading.Heal, args: %{kind: "wallet_bench"}}
    ]
  ],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {10, :minutes}]

# The Wallet Bench's minute read (`Patchbay.WalletBench.Board`): Postgres
# cancels any one view's read that runs longer, so it frees its connection.
config :patchbay, Patchbay.WalletBench.Board, statement_timeout: 5_000

# The operator wallet signs Patchbay's own sends on Base, so the site poller
# reads the age of each flow's oldest unconfirmed one (`PatchbayWeb.Telemetry`).
config :patchbay, PatchbayWeb.Telemetry,
  unconfirmed_sends: {Patchbay.OperatorWallet, :unconfirmed_sends, []}

# Metrics listen on loopback, on a port the system picks, so this site runs
# beside the others; production names the port Fly reads (config/prod.exs).
config :patchbay, :metrics_listener, ip: {127, 0, 0, 1}, port: 0

# The engine's memory, run queues and process counts are measured every
# 10 seconds by telemetry_poller's default poller and exported as `vm.*` metrics.
config :telemetry_poller, :default, period: 10_000

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
    Patchbay.Points,
    Patchbay.WalletBench,
    Patchbay.Accounts,
    Patchbay.AnswerWatch
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
  "patchbay.help" => ~w(get_patchbay_help get_webmcp_guide read_site_directory search_threads
       get_thread get_tool_history get_agent_profile)
}

# An MCP events subscription's callback answers a signed challenge before
# anything is stored, and is posted its events as they happen
# (`Patchbay.Forum.EventSubscription`).
config :patchbay, Patchbay.Forum.EventSubscription, webhooks: Regent.MCPEvents

# Paid actions, through the Regents payments library shared by every Regent
# site: a tip to an agent profile, a paid priority report and a paid assist.
# The payment records live in the shared `regent_payments` schema, which
# `bin/migrate-shared` applies; Patchbay reads and writes only its own rows.
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

# The post each of Regents' own error codes leads to from its lasting link,
# /errors/<code> (`PatchbayWeb.ErrorLinkController`): the code, then the post's id.
# The Regents command line prints these links beside its errors, so a code here
# is never renamed; when a better post is written, its id replaces the old one.
config :patchbay, :error_links, %{
  "not_signed_in" => "bc85f337-9965-4a8c-9a4e-ea875b3a55ce",
  "agent_not_paired" => "54444861-6b25-4918-abb9-dd6f98b76380",
  "person_not_here" => "d6a3cc57-124c-41ff-a8fb-bc7d2b1095cc",
  "no_touch_id" => "f308a148-c8af-47ea-845d-7c402c07c76d",
  "key_helper_not_answering" => "f308a148-c8af-47ea-845d-7c402c07c76d",
  "locked_key_needs_mac" => "f308a148-c8af-47ea-845d-7c402c07c76d",
  "code_sign_in" => "4a53f1bb-e031-4142-b268-cfe32a1619f0"
}

# Which name a signed-in person is shown by when they have both: `:chosen`, their
# Regents account name, or `:ens`, their wallet's ENS name. Each Regent site picks one.
config :patchbay, :name_first, :ens

# The build /capabilities.json and the hosted MCP server's serverInfo.version
# name. A deployed image sets its commit and image (config/runtime.exs); a
# machine built from no commit, a laptop or the tests, is "local".
config :patchbay, :build, %{commit: "local", release: nil}

# Production marks the session cookie HTTPS-only; local runs serve plain HTTP.
config :patchbay, :secure_session_cookie, false

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
      ~w(js/app.ts js/theme.ts --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
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
  metadata: [:request_id, :error_type, :visit, :actor, :surface, :event]

# Failed requests, pages and jobs are saved in the site's own schema (set in
# config/runtime.exs) and shown to Credits admins at /admin/errors. Only server
# faults are saved (Patchbay.ErrorIgnorer), only where each one happened is kept
# (Patchbay.ErrorFilter), and Patchbay.ErrorPruner clears each one a week after
# it was last seen.
config :error_tracker,
  repo: Patchbay.Repo,
  otp_app: :patchbay,
  prefix: "public",
  ignorer: Patchbay.ErrorIgnorer,
  filter: Patchbay.ErrorFilter

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Every page also answers `Accept: text/markdown` with a markdown document.
# The only `.eex` templates in this application are those markdown ones.
config :phoenix_template, :template_engines, eex: PatchbayWeb.MarkdownEngine

# Logs never show these values. Phoenix matches by part of a name, so the
# words a search sends (`q`) are kept out by the search routes' own `log:
# false` (router.ex) and the search window's (`PatchbayWeb.SearchLive`).
config :phoenix, :filter_parameters, [
  "password",
  "payment_signature",
  "code",
  "code_verifier",
  "access_token",
  "refresh_token",
  "client_secret",
  "id_token",
  "_csrf_token"
]

# The screenshot machine: a separate Fly app on the private network that
# runs the browser for site cards and holds no keys.
config :patchbay, :shots_url, "http://patchbay-shots.flycast"

# Rate limits key on the direct peer. Production turns on Fly's client header.
config :patchbay, :behind_fly_proxy, false

# How often one person may save each kind of writing others read, and how often
# one client address may search from a page, each window (Patchbay.Limits), as in
# ash-template. Forum posts keep their own hourly share (PatchbayWeb.Forum.PostingBudget).
config :patchbay, :limits,
  credits_help_post: [limit: 10, window_seconds: 3600],
  search_address: [limit: 300, window_seconds: 60]

# The wallet paid by the Wallet Bench's paid-call test page
# (`PatchbayWeb.Plugs.X402Test`): the Bench's own funder wallet, which
# Techtree holds and Patchbay does not. It is not where Patchbay is paid.
config :patchbay, :x402_test_pay_to, "0x786C67651BcB148f5A383A150E78bD4Ed9f64f7b"

# The incident pages' files (`Patchbay.Incidents`), relative to platform/.
config :patchbay, :incident_files, ["priv/incidents/*.md"]

# Sites are registrable domains, read from the Public Suffix List bundled with
# domainatrex. Builds use that copy and never fetch the list.
config :domainatrex, fetch_latest: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Privy consent for watching events. The identity and posting permissions are
# added in config/runtime.exs when ChatGPT identities are switched on. ChatGPT
# connects at the open address (PatchbayWeb.SiteEdition).
config :patchbay, Patchbay.OAuth,
  enabled?: false,
  brand: "patchbay",
  issuer: "https://open.patchbay.help",
  resource: "https://open.patchbay.help/chatgpt/mcp",
  scope: "patchbay.events.read",
  permission_description:
    "watch replies and asker-selected solutions on threads you choose or follow",
  consent_note:
    "Patchbay never lets a connection make payments, change wallets or choose solutions. Posting, when allowed, is free questions and replies only."
