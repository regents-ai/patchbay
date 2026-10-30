defmodule Patchbay.ReleaseTest do
  # The release commands every site carries, run against disposable databases:
  # the launchers, the staging bootstrap, the listing of what a database and the
  # release disagree about, and the shared changes a deployment never applies.
  # Then Patchbay's own: the release connection and the imported history.
  # The bootstrap and listing cases point the application repository at a
  # disposable database, so this module runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Patchbay.LocalDatabaseFixture
  alias Patchbay.Release
  alias Patchbay.Repo

  @moduletag timeout: 300_000

  @role "PATCHBAY_DEPLOYMENT_ROLE"
  @role_error "bootstrap-staging requires PATCHBAY_DEPLOYMENT_ROLE to be exactly staging"
  @missing_table_error "no schema_migrations table: run bootstrap-staging first"
  @unreachable [
    hostname: "127.0.0.1",
    port: 1,
    database: "patchbay_refused",
    username: "nobody",
    password: nil,
    pool_size: 1
  ]

  # Several cases migrate a database from scratch inside one VM, so the same
  # migration modules are loaded more than once. That redefinition is expected
  # here and nothing else compiles while this module runs.
  setup do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, previous) end)
    :ok
  end

  test "every launcher runs its guarded command with no arguments and prints no variables" do
    for {path, command} <- [
          {"rel/overlays/bin/migrate", :migrate},
          {"rel/overlays/bin/migrate-shared", :migrate_shared},
          {"rel/overlays/bin/bootstrap-staging", :bootstrap_staging},
          {"rel/overlays/bin/pending-migrations", :pending_migrations}
        ] do
      script = File.read!(path)

      assert script ==
               """
               #!/bin/sh
               set -eu

               PATCHBAY_RELEASE_COMMAND=migrate exec "$(dirname "$0")/patchbay" eval 'Patchbay.Release.#{command}()'
               """

      assert File.stat!(path).mode |> Bitwise.band(0o100) != 0
      assert {command, 0} in Release.__info__(:functions)
    end
  end

  test "bootstrap refuses every role but staging before it opens a connection" do
    for role <- [nil, "", "production", "Staging", "staging ", "rehearsal"] do
      getenv = fn
        @role -> role
        name -> flunk("bootstrap read #{name} before it checked the deployment role")
      end

      assert_raise RuntimeError, @role_error, fn ->
        Release.bootstrap_staging(getenv: getenv, config: @unreachable)
      end
    end
  end

  test "bootstrap prepares an empty staging database and runs every migration to completion" do
    config = bootstrapped_database()

    assert "wallet_address" in column_names(config, "regent_names", "platform_human_users")
    assert applied_versions(config) == release_versions()
    assert capture_io(fn -> Release.migrate_shared(config: config) end) == "none\n"
  end

  test "bootstrap refuses a database that already carries migration state" do
    config = bootstrapped_database()

    assert_raise RuntimeError,
                 "public.schema_migrations already exists: destroy and recreate the staging database",
                 fn -> Release.bootstrap_staging(getenv: staging_getenv(), config: config) end
  end

  test "bootstrap refuses a database that already has the regent_names schema, and changes nothing" do
    config = disposable_database()
    query!(config, "CREATE SCHEMA regent_names")

    assert_raise RuntimeError,
                 "regent_names schema already exists: destroy and recreate the staging database",
                 fn -> Release.bootstrap_staging(getenv: staging_getenv(), config: config) end

    refute migration_table?(config)
  end

  test "the listing prints none on a database the release agrees with" do
    config = bootstrapped_database()

    assert capture_io(fn -> Release.pending_migrations(config: config) end) == "none\n"
  end

  test "the listing names every version the release carries that the database has not applied" do
    config = disposable_database()
    held_back = Enum.take(release_migration_files(), -1)

    bootstrap(config, migrations_directory(release_migration_files() -- held_back))

    assert capture_io(fn -> Release.pending_migrations(config: config) end) ==
             "pending: #{Enum.map_join(held_back, " ", &version_of/1)}\n"
  end

  test "the listing names every applied version whose file the release does not carry" do
    config = bootstrapped_database()

    query!(
      config,
      "INSERT INTO public.schema_migrations (version, inserted_at) VALUES ($1, NOW()::timestamp)",
      [20_990_101_000_000]
    )

    assert capture_io(fn -> Release.pending_migrations(config: config) end) ==
             "applied-without-file: 20990101000000\n"
  end

  test "the listing refuses a database with no migration table and creates nothing" do
    config = disposable_database()

    assert_raise RuntimeError, @missing_table_error, fn ->
      Release.pending_migrations(config: config)
    end

    refute migration_table?(config)
  end

  # A shared change missing from its own ledger is what a release carrying a
  # newer shared library meets: the listing names it, and the deployment check
  # refuses and applies nothing.
  test "a missing shared change is listed and stops the deployment check" do
    config = bootstrapped_database()
    assert with_repo(config, &Release.require_signed_access_schema!/1) == :ok
    [{schema, version} | _] = applied_shared(config)
    query!(config, "DELETE FROM #{schema}.schema_migrations WHERE version = $1", [version])

    assert capture_io(fn -> Release.pending_migrations(config: config) end) ==
             "shared-pending: #{schema} #{version}\n"

    assert_raise RuntimeError,
                 "These separately approved shared migrations must be applied before deployment: #{schema} #{version}",
                 fn -> with_repo(config, &Release.require_signed_access_schema!/1) end
  end

  test "migrate-shared applies every shared change this site carries, once" do
    config = disposable_database()
    with_repo(config, fn _repo -> LocalDatabaseFixture.create_shared_tables!() end)

    assert capture_io(fn -> Release.migrate_shared(config: config) end) ==
             "applied: #{Enum.join(shipped_shared(), ", ")}\n"

    assert capture_io(fn -> Release.migrate_shared(config: config) end) == "none\n"
  end

  test "the local fixture prepares only a local dev or test database" do
    local = [hostname: "127.0.0.1", database: "patchbay_test"]

    assert LocalDatabaseFixture.validate_target!(:test, local) == :ok

    assert LocalDatabaseFixture.validate_target!(
             :dev,
             hostname: "::1",
             database: "patchbay_browser_51634_dev"
           ) == :ok

    for {env, repo} <- [
          {:prod, local},
          {:test, Keyword.put(local, :hostname, "db.example.com")},
          {:test, Keyword.put(local, :hostname, "localhost")},
          {:test, Keyword.put(local, :database, "patchbay")},
          {:test, Keyword.put(local, :database, "patchbay_test_copy")}
        ] do
      assert_raise RuntimeError,
                   "local human-account fixture refused unsafe database target",
                   fn ->
                     LocalDatabaseFixture.validate_target!(env, repo)
                   end
    end
  end

  test "a running application connection cannot be reused for migration" do
    previous = Application.fetch_env!(:patchbay, Repo)
    pid = Process.whereis(Repo)
    assert is_pid(pid)

    assert_raise RuntimeError, ~r/fresh release eval/, fn ->
      Release.migrate(config: [url: "postgres://migration:fixture@127.0.0.1/unused"])
    end

    assert Process.whereis(Repo) == pid
    assert Application.fetch_env!(:patchbay, Repo) == previous
  end

  test "a fresh migration command uses the release connection, reruns harmlessly and restores runtime config" do
    config = disposable_database()
    with_repo(config, fn _repo -> LocalDatabaseFixture.create_shared_tables!() end)
    capture_io(fn -> Release.migrate_shared(config: config) end)

    # If the release falls back to runtime configuration, this user/database cannot connect.
    runtime = Keyword.merge(config, username: "unusable_runtime", database: "unusable_runtime")
    Application.put_env(:patchbay, Repo, runtime)
    url = release_url(config)

    Release.migrate(config: [url: url])
    assert Application.fetch_env!(:patchbay, Repo) == runtime
    refute Process.whereis(Repo)
    Release.migrate(config: [url: url])
    assert Application.fetch_env!(:patchbay, Repo) == runtime

    assert applied_versions(config) == release_versions()
  end

  test "an index a stopped build left unusable stops the release, and migrate builds it again" do
    config = disposable_database()
    with_repo(config, fn _repo -> LocalDatabaseFixture.create_shared_tables!() end)
    capture_io(fn -> Release.migrate_shared(config: config) end)
    url = release_url(config)
    Release.migrate(config: [url: url])

    # A unique index built over two equal rows stops part way, as a build that
    # loses its machine does, and is left behind unusable. One takes the name
    # of a search index whose migration then never finished.
    query!(config, "CREATE TABLE public.stopped_build(x integer)")
    query!(config, "INSERT INTO public.stopped_build VALUES (1), (1)")
    query!(config, "DROP INDEX public.forum_sites_search_words_index")
    query!(config, "DELETE FROM public.schema_migrations WHERE version = 20261030095701")

    for name <- ~w(forum_sites_search_words_index stopped_build_x) do
      assert_raise Postgrex.Error, fn ->
        query!(config, "CREATE UNIQUE INDEX CONCURRENTLY #{name} ON public.stopped_build (x)")
      end
    end

    # The search index's migration runs again and rebuilds it; the other has
    # no migration, so the release stops and names it.
    assert_raise RuntimeError,
                 "Unusable indexes left by a stopped build: stopped_build_x. Run migrate again.",
                 fn -> Release.migrate(config: [url: url]) end

    assert query!(
             config,
             "SELECT indisvalid, indrelid::regclass::text FROM pg_index WHERE indexrelid = 'public.forum_sites_search_words_index'::regclass"
           ).rows == [[true, "forum_sites"]]

    assert applied_versions(config) == release_versions()
  end

  test "incomplete imported history stops before changing either ledger" do
    config = disposable_database()

    options =
      Keyword.merge(config, default_prefix: "patchbay", migration_default_prefix: "patchbay")

    query!(config, "CREATE SCHEMA patchbay")

    query!(
      config,
      "CREATE TABLE public.schema_migrations(version bigint PRIMARY KEY, inserted_at timestamp)"
    )

    query!(config, "INSERT INTO public.schema_migrations VALUES (1, now())")

    query!(
      config,
      "CREATE TABLE patchbay.schema_migrations (LIKE public.schema_migrations INCLUDING ALL)"
    )

    Application.put_env(:patchbay, Repo, options)

    assert_raise RuntimeError, ~r/Import the complete Patchbay schema/, fn ->
      Release.migrate(config: [url: release_url(config)])
    end

    assert Application.fetch_env!(:patchbay, Repo) == options
    refute Process.whereis(Repo)
    assert query!(config, "SELECT version FROM public.schema_migrations").rows == [[1]]
    assert query!(config, "SELECT version FROM patchbay.schema_migrations").rows == []
  end

  test "under production's schema the search change applies and finds words spelled a little wrong" do
    config = production_schema_database()

    assert query!(
             config,
             "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_trgm'"
           ).rows == [["public"]]

    with_repo(config, fn _repo ->
      site = Patchbay.Forum.register_site!("kettlebell.example")

      Patchbay.Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://kettlebell.example/",
        name: "empty_basket",
        contract_sha256: String.duplicate("a", 64)
      })

      question =
        Patchbay.Forum.ask_question!(
          %{
            site_id: site.id,
            browser_session_id: Ash.UUID.generate(),
            title: "The kettlebell basket never empties",
            thread_kind: :help_needed,
            body_markdown: "Asked on the board."
          },
          authorize?: false
        )

      assert [%{id: site_id}] = Patchbay.Forum.find_sites!("ketlebell")
      assert site_id == site.id
      assert [%{name: "empty_basket"}] = Patchbay.Forum.find_tools!("empty_baskt")
      assert [%{id: question_id}] = Patchbay.Forum.search_threads!("ketlebell").results
      assert question_id == question.id
    end)

    # Undoing the change leaves the extension: other sites on the shared
    # database may use it.
    with_repo(config, fn repo ->
      Ecto.Migrator.run(repo, [release_migrations_path()], :down,
        to: 20_261_027_233_519,
        prefix: "patchbay_app"
      )
    end)

    assert query!(config, "SELECT count(*) FROM pg_extension WHERE extname = 'pg_trgm'").rows ==
             [[1]]
  end

  test "under production's schema the send times are given to the sends already waiting" do
    config = production_schema_database()
    version = 20_261_029_203_941
    migration = Patchbay.Repo.Migrations.OperatorSendTimes

    filed_at =
      with_repo(config, fn _repo ->
        asker =
          Patchbay.Identity.upsert_from_privy!(%{
            privy_user_id: "did:privy:release-send-times",
            wallet_address: "0x" <> String.duplicate("a", 40)
          })

        site = Patchbay.Forum.register_site!("kettlebell.example")

        tool =
          Patchbay.Forum.observe_tool!(%{
            site_id: site.id,
            address: "https://kettlebell.example/",
            name: "empty_basket",
            contract_sha256: String.duplicate("a", 64)
          })

        report =
          Patchbay.Forum.file_priority_report!(
            %{
              tool_id: tool.id,
              browser_session_id: Ash.UUID.generate(),
              arguments_sha256: String.duplicate("b", 64),
              verdict: :verified_failure,
              note: "The basket never empties.",
              priority_amount_atomic: 5_000_000,
              payment_intent_id: Ash.UUID.generate()
            },
            actor: asker
          )

        {:ok, _claimed} = Patchbay.Forum.claim_escrow_credit(report, authorize?: false)
        report.inserted_at
      end)

    output =
      capture_io(fn ->
        with_repo(config, fn repo ->
          Ecto.Migrator.down(repo, version, migration, prefix: "patchbay_app", log: false)
          Ecto.Migrator.up(repo, version, migration, prefix: "patchbay_app", log: false)
        end)
      end)

    assert output =~ "forum_reports: 1 waiting credit(s) given a send time"

    assert query!(config, "SELECT escrow_credit_sent_at FROM patchbay_app.forum_reports").rows ==
             [[DateTime.to_naive(filed_at)]]
  end

  # Production imported its tables and their migration ledger into
  # patchbay_app and migrates from there. Here: every migration production
  # has run in public, the tables moved, then the rest under the prefix.
  # Oban's jobs stay in public, where this test run's Oban reads them.
  defp production_schema_database do
    public = disposable_database()

    config =
      Keyword.merge(public,
        default_prefix: "patchbay_app",
        migration_default_prefix: "patchbay_app"
      )

    with_repo(public, fn _repo -> LocalDatabaseFixture.create_shared_tables!() end)
    capture_io(fn -> Release.migrate_shared(config: public) end)

    with_repo(public, fn repo ->
      Ecto.Migrator.run(repo, [release_migrations_path()], :up, to: 20_261_027_073_355)
      Ecto.Adapters.SQL.query!(repo, "CREATE SCHEMA patchbay_app", [])
      move_to_patchbay_app(repo)
    end)

    with_repo(config, fn repo ->
      Ecto.Migrator.run(repo, [release_migrations_path()], :up, all: true, prefix: "patchbay_app")
    end)

    config
  end

  # Every table and view in public but Oban's, as production's import moved them.
  defp move_to_patchbay_app(repo) do
    for [name, kind] <-
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v') AND c.relname NOT LIKE 'oban_%' ORDER BY c.relkind",
            []
          ).rows do
      object = if kind == "v", do: "VIEW", else: "TABLE"

      Ecto.Adapters.SQL.query!(
        repo,
        ~s(ALTER #{object} public."#{name}" SET SCHEMA patchbay_app),
        []
      )
    end
  end

  defp staging_getenv do
    fn
      @role -> "staging"
      _name -> nil
    end
  end

  defp bootstrap(config, migrations_path \\ release_migrations_path()) do
    Release.bootstrap_staging(
      getenv: staging_getenv(),
      config: config,
      migrations_path: migrations_path
    )
  end

  defp bootstrapped_database do
    config = disposable_database()
    bootstrap(config)
    config
  end

  # The application repository is running against the shared test database, so
  # every case that points the release commands somewhere else takes it down
  # first and puts it back exactly as it was.
  defp disposable_database do
    previous = Application.fetch_env!(:patchbay, Repo)
    assert previous[:hostname] == "127.0.0.1"
    refute previous[:url]
    assert String.ends_with?(previous[:database], "_test")

    config =
      Keyword.merge(previous,
        database: "patchbay_release_#{System.unique_integer([:positive])}",
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    :ok = Supervisor.terminate_child(Patchbay.Supervisor, Repo)
    :ok = Ecto.Adapters.Postgres.storage_up(config)

    on_exit(fn ->
      Ecto.Adapters.Postgres.storage_down(config)
      Application.put_env(:patchbay, Repo, previous)
      {:ok, _pid} = Supervisor.restart_child(Patchbay.Supervisor, Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    config
  end

  # The database as a URL, the shape `DATABASE_DIRECT_URL` gives the release.
  defp release_url(config) do
    "postgresql://#{URI.encode_www_form(config[:username])}:fixture@127.0.0.1:#{config[:port] || 5432}/#{config[:database]}"
  end

  defp migrations_directory(files) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "patchbay-release-migrations-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    for file <- files,
        do: File.cp!(Path.join(release_migrations_path(), file), Path.join(directory, file))

    directory
  end

  defp release_migrations_path, do: Application.app_dir(:patchbay, "priv/repo/migrations")

  defp release_migration_files do
    release_migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  defp release_versions, do: Enum.map(release_migration_files(), &version_of/1)

  defp version_of(file) do
    {version, "_" <> _name} = Integer.parse(file)
    version
  end

  defp applied_versions(config) do
    config
    |> query!("SELECT version FROM public.schema_migrations ORDER BY version")
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  # Every shared ledger's newest applied change, one per shared schema.
  defp applied_shared(config) do
    for schema <- ~w(regent_identity regent_agents regent_credits regent_points regent_payments),
        query!(config, "SELECT to_regclass($1) IS NOT NULL", ["#{schema}.schema_migrations"]).rows ==
          [[true]],
        %{rows: [[version]]} =
          query!(config, "SELECT max(version) FROM #{schema}.schema_migrations"),
        do: {schema, version}
  end

  # Every change the shared libraries this site carries ship, as the release
  # names them, in the order they apply.
  defp shipped_shared do
    for app <- [
          :regent_identity,
          :regent_agents,
          :regent_credits,
          :regent_points,
          :regent_payments
        ],
        file <-
          app
          |> Application.app_dir("priv/repo/migrations")
          |> Path.join("*.exs")
          |> Path.wildcard()
          |> Enum.sort(),
        do: "#{app} #{file |> Path.basename() |> version_of()}"
  end

  defp column_names(config, schema, table) do
    config
    |> query!(
      "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 ORDER BY column_name",
      [schema, table]
    )
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp migration_table?(config) do
    query!(config, "SELECT to_regclass('public.schema_migrations') IS NOT NULL").rows ==
      [[true]]
  end

  defp query!(config, sql, params \\ []) do
    with_repo(config, &Ecto.Adapters.SQL.query!(&1, sql, params))
  end

  defp with_repo(config, fun) do
    previous = Application.get_env(:patchbay, Repo)
    Application.put_env(:patchbay, Repo, config)

    try do
      {:ok, result, _started} = Ecto.Migrator.with_repo(Repo, fun)
      result
    after
      Application.put_env(:patchbay, Repo, previous)
    end
  end
end
