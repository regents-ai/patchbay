defmodule Patchbay.Repo do
  use AshPostgres.Repo,
    otp_app: :patchbay

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  def installed_extensions, do: ["ash-functions"]
end
