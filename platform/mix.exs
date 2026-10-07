defmodule Patchbay.MixProject do
  use Mix.Project

  # Shared Regent libraries, each pinned to one published commit. To move a pin,
  # change its ref and run `mix deps.update <name>`.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "f344888c70bd5983ff8a27339ac2db9a71594bd2"
  @design_system "https://github.com/regents-ai/design-system.git"
  @design_system_ref "4da6db2bfe3559a8f8a761018dc099a28ab5f6a3"
  @regents "https://github.com/regents-ai/regents.git"
  @regents_ref "d634da3cc5a0a975f5d3ff5d19a8c5443032a47c"

  def project do
    [
      app: :patchbay,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
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
  # `dev/` holds the payments lab, which only a machine of ours ever runs.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:regent_ui, git: @design_system, ref: @design_system_ref, sparse: "regent_ui"},
      {:regent_blog, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "blog"},
      {:regent_format, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "format"},
      {:regent_chain, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain"},
      {:regent_http, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "http"},
      {:regent_agent_access, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "agent_access"},
      {:regent_mcp_events, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "mcp_events"},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:ash, "~> 3.34 and >= 3.34.3"},
      {:ash_postgres, "== 2.13.0"},
      {:ash_phoenix, "~> 2.3"},
      {:oban, "~> 2.24"},
      {:ash_oban, "~> 0.9"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:simple_sat, "~> 0.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:mdex, "~> 0.13"},
      {:domainatrex, "~> 3.2"},
      {:regent_privy,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "privy", override: true},
      {:regent_identity, git: @regents, ref: @regents_ref, sparse: "identity"},
      {:regent_payments, git: @regents, ref: @regents_ref, sparse: "payments"},
      {:regent_agents, git: @regents, ref: @regents_ref, sparse: "agents"},
      {:siwa, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "siwa/siwa-elixir/apps/siwa"},
      {:x402, "0.9.0"},
      {:ethers, "0.8.0"},
      {:ex_secp256k1, "~> 0.8.0"},
      {:finch, "~> 0.19"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:hammer, "~> 7.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
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
        "ecto.migrate",
        "regent_payments.migrate",
        "regent_agents.migrate"
      ],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # The shared payment records' and agent pairings' own schemas, for a
      # database on this machine. Production's are migrated by Regents, never
      # from here.
      "regent_payments.migrate": [
        "run --no-start -e 'Application.ensure_all_started(:ecto_sql); RegentPayments.Migrator.up(Patchbay.Repo)'"
      ],
      "regent_agents.migrate": [
        "run --no-start -e 'Application.ensure_all_started(:ecto_sql); RegentAgents.Migrator.up(Patchbay.Repo)'"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "esbuild.install --if-missing",
        "cmd npm ci --prefix assets"
      ],
      "assets.build": [
        "compile",
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
        "esbuild patchbay",
        "esbuild patchbay_crown",
        "esbuild patchbay_privy"
      ],
      "assets.deploy": [
        "regent_ui.assets",
        "regent_blog.assets",
        "regent_identity.assets",
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
        "xref graph --label compile-connected --fail-above 33",
        "ash.codegen --check",
        "usage_rules.sync --check",
        "cmd npm run typecheck --prefix assets",
        "test --warnings-as-errors"
      ]
    ]
  end
end
