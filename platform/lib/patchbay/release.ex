defmodule Patchbay.Release do
  @moduledoc """
  Database tasks for the packaged release, where Mix is not available.
  """

  @app :patchbay
  # Last migration already present in the preserved source. Its predecessors
  # contain public-qualified references and must never replay after relocation.
  @imported_through 20_260_904_074_137

  # Every shared library with its own schema and ledger, in the order their
  # changes apply: Credits' pairing grants build on Agents' pairing history.
  @shared [
    {:regent_identity, "regent_identity", RegentIdentity.Migrator},
    {:regent_agents, "regent_agents", RegentAgents.Migrator},
    {:regent_credits, "regent_credits", RegentCredits.Migrator},
    {:regent_points, "regent_points", RegentPoints.Migrator},
    {:regent_payments, "regent_payments", RegentPayments.Migrator}
  ]

  @doc """
  Runs every pending migration over the release connection
  (`Patchbay.DatabaseConfig.release_config!/0`), or over `connection` when given.
  """
  def migrate(connection \\ Patchbay.DatabaseConfig.release_config!()) do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        with_migration_repo(repo, connection, fn repo ->
          require_imported_history!(repo)
          require_signed_access_schema!(repo)
          Ecto.Migrator.run(repo, :up, all: true, prefix: repo.default_prefix())
        end)
    end
  end

  @doc """
  Applies the shared database changes this release's pinned libraries carry
  that the database has not applied, and prints each one, or `none`. Run as
  `/app/bin/migrate-shared`.

  Every site carries this same command. A deployment never runs it: `migrate/1`
  refuses while a shared change is missing and applies none. Each change needs
  the founder's own named go; the site whose release first carries it runs this
  from the new image before that deployment, because only that image carries
  the change's file. Each library's ledger takes a migration lock, so two sites
  running it at once apply each change once.
  """
  def migrate_shared do
    load_app()

    {:ok, applied, _apps} =
      with_migration_repo(Patchbay.Repo, Patchbay.DatabaseConfig.release_config!(), fn repo ->
        unapplied = unapplied_shared_migrations(repo)
        if unapplied != [], do: apply_shared(repo)
        unapplied
      end)

    case applied do
      [] -> IO.puts("none")
      applied -> IO.puts("applied: #{Enum.join(applied, ", ")}")
    end
  end

  @doc "Read-only shared prerequisites; a deployment never applies shared migrations."
  def require_signed_access_schema!(repo) do
    :ok = require_shared_migrations!(repo)
    :ok = RegentAgents.Migrator.require_pairing_history!(repo)
    RegentCredits.Migrator.require_pairing_grants!(repo)
  end

  # The shared code this release carries reads tables and columns from every
  # migration its pinned library ships, so each must already be in that schema's
  # own ledger. Every missing version is named at once.
  defp require_shared_migrations!(repo) do
    case unapplied_shared_migrations(repo) do
      [] ->
        :ok

      unapplied ->
        raise "These separately approved shared migrations must be applied before deployment: " <>
                Enum.join(unapplied, ", ")
    end
  end

  defp unapplied_shared_migrations(repo) do
    for {app, schema, _migrator} <- carried_shared(),
        {:down, version, _name} <-
          Ecto.Migrator.migrations(repo, [Application.app_dir(app, "priv/repo/migrations")],
            prefix: schema,
            skip_table_creation: true,
            migration_lock: false
          ),
        do: "#{schema} #{version}"
  end

  defp apply_shared(repo), do: Enum.each(carried_shared(), fn {_, _, m} -> m.up(repo) end)

  # A shared library this site does not carry has no tables it reads or changes.
  defp carried_shared do
    carried = Application.spec(@app, :applications)
    for {app, _schema, _migrator} = shared <- @shared, app in carried, do: shared
  end

  def rollback(repo, version) do
    load_app()

    if repo.default_prefix() != "public" and version <= @imported_through do
      raise "Cannot roll back imported history in the shared database"
    end

    {:ok, _result, _apps} =
      with_migration_repo(repo, Patchbay.DatabaseConfig.release_config!(), fn repo ->
        require_imported_history!(repo)
        Ecto.Migrator.run(repo, :down, to: version, prefix: repo.default_prefix())
      end)
  end

  defp require_imported_history!(repo) do
    if repo.default_prefix() != "public" do
      migrations =
        Ecto.Migrator.migrations(repo, Ecto.Migrator.migrations_path(repo),
          prefix: repo.default_prefix(),
          skip_table_creation: true
        )

      incomplete? =
        Enum.any?(migrations, fn {status, version, _name} ->
          status == :down and version <= @imported_through
        end)

      if incomplete? do
        raise "Import the complete Patchbay schema and migration history before migrating"
      end
    end
  end

  # with_repo reuses a running Repo. Changing its configuration would not change
  # those existing credentials, so migration commands require a fresh release eval.
  # The release connection replaces every endpoint and login setting while the
  # schema and transport settings stay; it never falls back to the serving one.
  defp with_migration_repo(repo, connection, fun) do
    if Process.whereis(repo) do
      raise "Migration requires a fresh release eval; the application Repo is already running"
    end

    previous = Application.fetch_env!(@app, repo)

    Application.put_env(
      @app,
      repo,
      previous
      |> Keyword.drop([
        :url,
        :hostname,
        :port,
        :socket,
        :socket_dir,
        :endpoints,
        :username,
        :password,
        :database,
        :ssl,
        :socket_options,
        :prepare
      ])
      |> Keyword.merge(connection)
    )

    try do
      Ecto.Migrator.with_repo(repo, fun)
    after
      Application.put_env(@app, repo, previous)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_loaded(@app)
  end
end
