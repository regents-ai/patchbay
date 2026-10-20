defmodule Patchbay.ReleaseMigrationTest do
  use ExUnit.Case, async: false

  alias Patchbay.{Release, Repo}

  setup do
    previous = Application.fetch_env!(:patchbay, Repo)
    on_exit(fn -> Application.put_env(:patchbay, Repo, previous) end)
    :ok
  end

  test "a running application connection cannot be reused for migration" do
    previous = Application.fetch_env!(:patchbay, Repo)
    pid = Process.whereis(Repo)
    assert is_pid(pid)

    assert_raise RuntimeError, ~r/fresh release eval/, fn ->
      Release.migrate(url: "postgres://migration:fixture@127.0.0.1/unused")
    end

    assert Process.whereis(Repo) == pid
    assert Application.fetch_env!(:patchbay, Repo) == previous
  end

  test "a fresh migration command uses the release connection, reruns harmlessly and restores runtime config" do
    {config, database, name} = disposable_database()

    migrate_shared(database)

    # If the release falls back to runtime configuration, this user/database cannot connect.
    runtime = Keyword.merge(config, username: "unusable_runtime", database: "unusable_runtime")
    Application.put_env(:patchbay, Repo, runtime)

    url =
      "postgresql://#{URI.encode_www_form(config[:username])}:fixture@127.0.0.1:#{config[:port] || 5432}/#{name}"

    Release.migrate(url: url)
    assert Application.fetch_env!(:patchbay, Repo) == runtime
    refute Process.whereis(Repo)
    Release.migrate(url: url)
    assert Application.fetch_env!(:patchbay, Repo) == runtime

    {:ok, connection} = Postgrex.start_link(database)

    try do
      %{rows: [[^name, count]]} =
        Postgrex.query!(
          connection,
          "SELECT current_database(), count(*) FROM public.schema_migrations",
          []
        )

      assert count > 0
    after
      GenServer.stop(connection)
    end
  end

  test "a shared change not yet applied stops the release, which names it" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    assert :ok = Release.require_signed_access_schema!(Repo)

    %{rows: [[version]]} =
      Repo.query!("""
      DELETE FROM regent_credits.schema_migrations
      WHERE version = (SELECT max(version) FROM regent_credits.schema_migrations)
      RETURNING version
      """)

    assert_raise RuntimeError,
                 ~r/must be applied before deployment: regent_credits #{version}$/,
                 fn -> Release.require_signed_access_schema!(Repo) end
  end

  test "incomplete imported history stops before changing either ledger" do
    {config, database, name} = disposable_database()

    options =
      Keyword.merge(config, default_prefix: "patchbay", migration_default_prefix: "patchbay")

    Application.put_env(:patchbay, Repo, options)

    url =
      "postgresql://#{URI.encode_www_form(config[:username])}:fixture@127.0.0.1:#{config[:port] || 5432}/#{name}"

    {:ok, connection} = Postgrex.start_link(database)

    try do
      Postgrex.query!(connection, "CREATE SCHEMA patchbay", [])

      Postgrex.query!(
        connection,
        "CREATE TABLE public.schema_migrations(version bigint PRIMARY KEY, inserted_at timestamp)",
        []
      )

      Postgrex.query!(connection, "INSERT INTO public.schema_migrations VALUES (1, now())", [])

      Postgrex.query!(
        connection,
        "CREATE TABLE patchbay.schema_migrations (LIKE public.schema_migrations INCLUDING ALL)",
        []
      )

      assert_raise RuntimeError, ~r/Import the complete Patchbay schema/, fn ->
        Release.migrate(url: url)
      end

      assert Postgrex.query!(connection, "SELECT version FROM public.schema_migrations", []).rows ==
               [[1]]

      assert Postgrex.query!(connection, "SELECT version FROM patchbay.schema_migrations", []).rows ==
               []

      assert Application.fetch_env!(:patchbay, Repo) == options
      refute Process.whereis(Repo)
    after
      GenServer.stop(connection)
    end
  end

  # `bin/migrate-shared` applies every shared change before any site release
  # runs; the release only checks that they are there. Points refers to the
  # shared account table, which Regents owns.
  defp migrate_shared(database) do
    Application.put_env(:patchbay, Repo, database)
    RegentIdentity.Migrator.up(Repo)
    RegentAgents.Migrator.up(Repo)
    RegentCredits.Migrator.up(Repo)

    {:ok, connection} = Postgrex.start_link(database)

    try do
      for statement <- PatchbayDev.SharedAccountTable.statements(),
          do: Postgrex.query!(connection, statement, [])
    after
      GenServer.stop(connection)
    end

    RegentPoints.Migrator.up(Repo)
    RegentPayments.Migrator.up(Repo)
  end

  defp disposable_database do
    config = Repo.config()
    assert config[:hostname] in ["127.0.0.1", "localhost"]
    refute config[:url]
    assert String.starts_with?(config[:database], "patchbay_test")
    name = "patchbay_release_" <> String.replace(Ecto.UUID.generate(), "-", "")
    database = Keyword.merge(config, database: name, pool: DBConnection.ConnectionPool)
    assert :ok = Ecto.Adapters.Postgres.storage_up(database)

    :ok = Supervisor.terminate_child(Patchbay.Supervisor, Repo)

    on_exit(fn ->
      Application.put_env(:patchbay, Repo, config)
      {:ok, _} = Supervisor.restart_child(Patchbay.Supervisor, Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      :ok = Ecto.Adapters.Postgres.storage_down(database)
    end)

    {config, database, name}
  end
end
