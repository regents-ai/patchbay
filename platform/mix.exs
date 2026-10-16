defmodule Patchbay.MixProject do
  use Mix.Project

  # Shared Regent libraries, each pinned to one published commit. To move a pin,
  # change its ref and run `mix deps.update <name>`.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "97cc96438fa9b07004ba0c32330e325404bbcc64"
  @design_system "https://github.com/regents-ai/design-system.git"
  @design_system_ref "c59303bfc64af0e588afe1b25775ea0ac6bcaed0"

  def project do
    [
      app: :patchbay,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:ash_signals, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      usage_rules: usage_rules()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Patchbay.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  # `dev/` holds the payments lab, which only a machine of ours ever runs, and
  # the shared account table a database on this machine gets.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:regent_oauth,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "oauth", override: true},
      {:regent_mcp_agents, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "mcp_agents"},
      {:regent_ui, git: @design_system, ref: @design_system_ref, sparse: "regent_ui"},
      {:regent_blog, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "blog"},
      # regent_payments pins its own elixir-utils commit; this pin replaces it.
      {:regent_format,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "format", override: true},
      # regent_credits names regent_chain by a sibling path; this pin replaces it.
      {:regent_chain,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain", override: true},
      {:regent_credits, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "credits"},
      {:regent_points, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "points"},
      {:regent_http, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "http"},
      {:regent_agent_access, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "agent_access"},
      {:regent_mcp_events, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "mcp_events"},
      {:ens_elixir, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ens"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.6", override: true},
      {:ash, "~> 3.36"},
      {:ash_postgres, "== 2.13.0"},
      {:ash_phoenix, "~> 2.3.25"},
      {:oban, "~> 2.24"},
      {:ash_oban, "~> 0.10.0"},
      {:igniter, "== 0.8.4", only: [:dev, :test], runtime: false},
      {:simple_sat, "~> 0.1"},
      # Shared baseline: compatible with Cachex 4.1.1 and Nebulex Distributed.
      {:ex_hash_ring, "== 6.0.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.16"},
      {:req, "== 0.7.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      # 3.1.1 has the EEF-CVE-2026-97853 advisory in Decimal.round/3.
      {:decimal, "== 3.2.0"},
      {:jason, "~> 1.2"},
      {:error_tracker, "~> 0.9"},
      {:mdex, "== 0.14.2"},
      {:domainatrex, "~> 3.2"},
      {:regent_privy,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "privy", override: true},
      {:regent_identity,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ash_components/identity"},
      {:regent_payments,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ash_components/payments"},
      {:regent_agents,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "ash_components/agents", override: true},
      # regent_agents pins its own elixir-utils commit; this pin replaces it.
      {:siwa,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "siwa/siwa-elixir/apps/siwa",
       override: true},
      {:x402, "0.9.0"},
      {:ethers, "0.8.0"},
      {:ex_secp256k1, "~> 0.8.0"},
      {:finch, "~> 0.19"},
      {:dns_cluster, "~> 0.3.0"},
      {:bandit, "~> 1.13"},
      {:hammer, "~> 7.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.2.8", only: [:dev, :test], runtime: false},
      {:credo_ash,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "credo_ash",
       only: [:dev, :test],
       runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  # `mix usage_rules.sync` writes the marked block at the end of AGENTS.md: how to
  # read the installed version's docs, and links to each package's own rules in deps/.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:usage_rules, sub_rules: []},
        {:usage_rules, sub_rules: :all, main: false, link: :markdown},
        {:ash, link: :markdown},
        {~r/^ash_/, link: :markdown},
        {:phoenix, sub_rules: ["phoenix", "liveview", "html"], link: :markdown}
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": [
        "ecto.create",
        "shared_account_table.create",
        "ecto.migrate",
        "regent_payments.migrate",
        "regent_agents.migrate",
        "regent_credits.migrate",
        "regent_points.migrate"
      ],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # The shared account table, which Patchbay's migrations refer to, and the
      # shared payment records', agent pairings', Credits' and Points' own schemas,
      # for a database on this machine. Production's are migrated by Regents,
      # never from here.
      "shared_account_table.create": [
        "run --no-start -e 'Ecto.Migrator.with_repo(Patchbay.Repo, fn repo -> Enum.each(PatchbayDev.SharedAccountTable.statements(), &repo.query!/1) end)'"
      ],
      "regent_payments.migrate": [
        "run --no-start -e 'Application.ensure_all_started(:ecto_sql); RegentPayments.Migrator.up(Patchbay.Repo)'"
      ],
      "regent_agents.migrate": [
        "run --no-start -e 'Application.ensure_all_started(:ecto_sql); RegentAgents.Migrator.up(Patchbay.Repo)'"
      ],
      "regent_credits.migrate": [
        "run --no-start -e 'Application.ensure_all_started(:ecto_sql); RegentCredits.Migrator.up(Patchbay.Repo)'"
      ],
      "regent_points.migrate": [
        "run --no-start -e 'Application.ensure_all_started(:ecto_sql); RegentPoints.Migrator.up(Patchbay.Repo)'"
      ],
      test: [
        "ecto.create --quiet",
        "shared_account_table.create",
        "ecto.migrate --quiet",
        "test"
      ],
      "assets.setup": [
        "esbuild.install --if-missing",
        "cmd npm ci --prefix assets"
      ],
      "assets.build": [
        "compile",
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        "esbuild patchbay",
        "esbuild patchbay_crown",
        "esbuild patchbay_privy"
      ],
      "assets.deploy": [
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "regent_agent_access.assets",
        "esbuild patchbay --minify",
        "esbuild patchbay_crown --minify",
        "esbuild patchbay_privy --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # Canonical accounts and the two owned-subscription policy checks add
        # three required compile connections to the previous 59-connection budget;
        # the saved-errors page's admin check (a router plug and mount hook) adds one.
        # The moderator check depends on no other Patchbay module, so the Offers
        # and Credits help policies that name it add none. The bench's set
        # summaries are one more resource its domain must name, which adds one,
        # and so are the forum's record of each post Jev read, the bench's
        # extra notes and an account's ENS name and picture.
        "xref graph --label compile-connected --fail-above 64",
        "ash.codegen --check",
        "usage_rules.sync --check",
        "cmd npm run typecheck --prefix assets",
        "test --warnings-as-errors"
      ]
    ]
  end
end
