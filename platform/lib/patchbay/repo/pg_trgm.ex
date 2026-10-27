defmodule Patchbay.Repo.PgTrgm do
  @moduledoc """
  pg_trgm, which scores how closely search words match a site, a tool or a
  thread title, typos included. The database is shared with every Regent site,
  so the extension lives in `public` whatever schema Patchbay's tables are in,
  and every use names it there (`OPERATOR(public.<%)`). Other sites may use it
  too, so rolling back never removes it.
  """

  use AshPostgres.CustomExtension, name: "pg_trgm", latest_version: 1

  @impl true
  def install(0), do: ~s|execute("CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public")|

  @impl true
  def uninstall(_version), do: ""
end
