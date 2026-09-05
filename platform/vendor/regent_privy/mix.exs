defmodule RegentPrivy.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Shared Privy identity-token verification for Regent Elixir apps."

  def project do
    [
      app: :regent_privy,
      version: @version,
      elixir: "~> 1.19.5",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [check: :test, precommit: :test]
    ]
  end

  defp deps do
    [
      {:joken, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: [
        ".formatter.exs",
        "CHANGELOG.md",
        "README.md",
        "lib",
        "mix.exs"
      ],
      licenses: ["MIT"],
      links: %{
        "Source" => "https://github.com/regents-ai/regent/tree/main/elixir-utils/privy"
      }
    ]
  end

  defp aliases do
    [
      check: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "test"
      ],
      precommit: ["check"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
