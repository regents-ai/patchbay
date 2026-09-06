defmodule Patchbay.Repo do
  use AshPostgres.Repo,
    otp_app: :patchbay

  @impl true
  def default_prefix do
    Application.get_env(:patchbay, __MODULE__, []) |> Keyword.get(:default_prefix, "public")
  end

  @impl true
  def default_options(_operation), do: [prefix: default_prefix()]

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["ash-functions"]
end
