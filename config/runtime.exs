import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/patchbay start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :patchbay, PatchbayWeb.Endpoint, server: true
end

config :patchbay, PatchbayWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Signing in. PRIVY_APP_ID is the Privy application this deployment belongs to,
# and PRIVY_VERIFICATION_KEY is that application's public ES256 key, not its
# secret. A deployment that sets neither still serves every page; the sign-in
# control simply says that signing in is not set up here.
#
# Fly hands multi-line secrets back with the newlines escaped, so both
# spellings of the PEM are accepted.
privy_verification_key =
  case System.get_env("PRIVY_VERIFICATION_KEY") do
    nil ->
      nil

    value ->
      value
      |> String.replace("\\r\\n", "\n")
      |> String.replace("\\n", "\n")
  end

config :patchbay, :privy,
  app_id: System.get_env("PRIVY_APP_ID"),
  verification_key: privy_verification_key

# The service that verifies and settles an x402 payment on Base mainnet.
# Patchbay never holds the money: the payment travels from the payer's wallet
# straight to the recipient's, and this is the only party Patchbay talks to
# about it.
#
# Everywhere, including production, that service is Coinbase's hosted
# facilitator, the one the x402 package documents for Base mainnet. Its address
# is public, so it is written here rather than kept as a secret, and nothing has
# to be set for Patchbay to start. X402_FACILITATOR_URL points Patchbay at a
# different facilitator when there is a reason to.
#
# CDP_API_KEY_ID and CDP_API_KEY_SECRET are that facilitator's credentials. A
# machine started without them still boots, and only a payment attempt fails,
# so a developer can run every unpaid part of Patchbay with no account.
facilitator_url =
  case System.get_env("X402_FACILITATOR_URL") do
    url when is_binary(url) and url != "" -> url
    _unset -> X402.Facilitator.Auth.CDP.facilitator_url()
  end

facilitator_auth =
  case {System.get_env("CDP_API_KEY_ID"), System.get_env("CDP_API_KEY_SECRET")} do
    {id, secret} when is_binary(id) and id != "" and is_binary(secret) and secret != "" ->
      {X402.Facilitator.Auth.CDP, api_key_id: id, api_key_secret: secret}

    _absent ->
      nil
  end

config :patchbay, Patchbay.Payments.Facilitator,
  url: facilitator_url,
  finch: Patchbay.Payments.Finch,
  auth: facilitator_auth

# The Base mainnet endpoint Patchbay reads USDC balances through, one JSON-RPC
# call per reading. Nothing else needs it: a machine started without it serves
# everything but the balance reading, which answers that it is not set up
# here. The address may carry the provider's own key, so it is kept a secret.
config :patchbay, :base_rpc_url, System.get_env("BASE_RPC_URL")
# Paid priority reports. ESCROW_CONTRACT_ADDRESS is the PatchbayEscrow
# contract on Base that holds an asker's money; OPERATOR_PRIVATE_KEY is the
# key of the account allowed to record and release it, and BASE_RPC_URL is the
# endpoint those transactions are sent to. A machine started without the
# address serves every unpaid part of Patchbay and says that paid priority
# posts are not set up; one started without the key or the endpoint still
# takes the money into escrow and leaves recording it for a person to re-run.
config :patchbay, :escrow,
  contract_address: System.get_env("ESCROW_CONTRACT_ADDRESS"),
  operator_private_key: System.get_env("OPERATOR_PRIVATE_KEY"),
  rpc_url: System.get_env("BASE_RPC_URL")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :patchbay, Patchbay.Repo,
    # No TLS: docs/DEPLOY.md targets an unmanaged `fly postgres create` cluster,
    # which is reached only over the app's private IPv6 network. A managed or
    # off-platform database needs `ssl: true` here.
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      It must be the public hostname the room is served from, for example:
      patchbay-regents.fly.dev
      """

  # Live inference and the deterministic demo fallback are read directly from
  # the environment by the generation path (OPENAI_API_KEY and
  # PATCHBAY_DEMO_FALLBACK), so they need no configuration here. Both are
  # optional; see docs/DEPLOY.md.
  #
  # The spend limits are read the same way, on demand, so a machine picks up
  # whatever it was started with: PATCHBAY_DAILY_MODEL_CALLS (default 300),
  # PATCHBAY_ROOM_DAILY_MODEL_CALLS (default 30) and
  # PATCHBAY_ROOM_COOLDOWN_SECONDS (default 20). Setting any of them to
  # something that is not a whole number leaves its default standing, so read
  # the value back with `fly secrets list` after changing one.

  config :patchbay, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :patchbay, PatchbayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :patchbay, PatchbayWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :patchbay, PatchbayWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :patchbay, Patchbay.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
