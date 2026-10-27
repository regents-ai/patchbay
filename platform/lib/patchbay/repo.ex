defmodule Patchbay.Repo do
  use AshPostgres.Repo,
    otp_app: :patchbay

  @impl true
  def default_prefix do
    Application.get_env(:patchbay, __MODULE__, []) |> Keyword.get(:default_prefix, "public")
  end

  # Ash qualifies reads with `default_prefix/0`; writes, upserts, `Ash.update_many`
  # and plain Ecto queries take the prefix from here instead (upserts and
  # `update_many` through Regent's ash_postgres copy, ash-project/ash_postgres#910).
  # An explicit prefix, such as a resource's own schema, always wins over this default.
  @impl true
  def default_options(_operation), do: [prefix: default_prefix()]

  # PostgreSQL's own catalog (`pg_class`, `pg_namespace`, ...) is never in this
  # schema, so a read of it drops the default above. ErrorTracker's migration
  # reads it.
  @impl true
  def prepare_query(_operation, %{from: %{source: {"pg_" <> _table, nil}}} = query, opts),
    do: {query, Keyword.delete(opts, :prefix)}

  def prepare_query(_operation, query, opts), do: {query, opts}

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["ash-functions", Patchbay.Repo.PgTrgm]
end
