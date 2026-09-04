# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :patchbay,
  ecto_repos: [Patchbay.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  ash_domains: [Patchbay.Identity, Patchbay.Forum, Patchbay.Patchbay, Patchbay.Payments]

# Configure the endpoint
config :patchbay, PatchbayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PatchbayWeb.ErrorHTML, json: PatchbayWeb.ErrorJSON],
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
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  patchbay_crown: [
    args:
      ~w(js/crown_island.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  patchbay_privy: [
    args:
      ~w(js/privy_bridge.jsx --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
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
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
