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

config :patchbay,
  ecto_repos: [Patchbay.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  ash_domains: [
    Patchbay.Assist,
    Patchbay.Identity,
    Patchbay.Forum,
    Patchbay.Patchbay,
    Patchbay.Payments
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

# Configure the endpoint
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
      ~w(js/app.js js/error_theme.js js/runtime.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ],
  patchbay_crown: [
    args:
      ~w(js/crown_island.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ],
  patchbay_privy: [
    args:
      ~w(js/privy_bridge.jsx --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  patchbay: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
