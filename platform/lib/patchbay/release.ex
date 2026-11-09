defmodule Patchbay.Release do
  @moduledoc """
  Database tasks for the packaged release, where Mix is not available, and the
  console's commands for suspending and reinstating a profile.
  """

  alias Patchbay.Identity

  @app :patchbay
  # Patchbay's console acts as the system actor, the only actor that may
  # suspend, reinstate or read their record (`Patchbay.Identity.AgentProfile`,
  # `Patchbay.Identity.StatusChange`). Code builds it; no request supplies it.
  @system %{role: :system}
  @console [actor: @system, not_found_error?: false]
  @platform_schema "regent_names"
  # Last migration already present in the preserved source. Its predecessors
  # contain public-qualified references and must never replay after relocation.
  @imported_through 20_260_904_074_137

  # The release connection replaces every endpoint and login setting while the
  # schema and transport settings stay.
  @connection_keys [
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
  ]

  @table_exists """
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p')
  )
  """
  @schema_exists "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = $1)"

  @unusable_indexes """
  SELECT c.relname FROM pg_catalog.pg_index AS i
  JOIN pg_catalog.pg_class AS c ON c.oid = i.indexrelid
  JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND NOT i.indisvalid
  ORDER BY c.relname
  """

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
  (`Patchbay.DatabaseConfig.release_config!/1`), then stops if any index in
  Patchbay's schema is unusable. Its options are the bootstrap's: `:config`
  names another connection.
  """
  def migrate(opts \\ []) when is_list(opts) do
    with_release_repo(opts, fn repo ->
      require_imported_history!(repo, migrations_path())
      require_signed_access_schema!(repo)
      run_migrations!(repo, migrations_path())
      require_usable_indexes!(repo)
    end)
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
  running it at once apply each change once. Its options are the bootstrap's.
  """
  def migrate_shared(opts \\ []) when is_list(opts) do
    applied =
      with_release_repo(opts, fn repo ->
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
        version <-
          unapplied_versions(repo, schema, Application.app_dir(app, "priv/repo/migrations")),
        do: "#{schema} #{version}"
  end

  # A read only: with its table creation skipped and no migration lock the
  # migrator just selects the schema's ledger. A library whose ledger does not
  # exist yet has had none of its changes applied.
  defp unapplied_versions(repo, schema, path) do
    if table_exists?(repo, schema, "schema_migrations") do
      for {:down, version, _name} <-
            Ecto.Migrator.migrations(repo, [path],
              prefix: schema,
              skip_table_creation: true,
              migration_lock: false
            ),
          do: version
    else
      Enum.sort(carried_versions(path))
    end
  end

  @doc """
  Prepares an empty staging database for the first deployment: creates a
  staging-only copy of the tables this repository reads but does not own
  (`regent_names.platform_human_users`), in the local fixture's shape, applies
  every shared change this release carries, as `migrate_shared/1` does in
  production, then runs every migration into the Repo's schema
  (`prepare_database!/2`). It refuses a database that already carries migration
  state or the regent_names schema and repairs nothing: recovery from a
  half-finished bootstrap is to destroy and recreate the staging database.

  The deployed launcher passes no options, so it reads only the database the
  release configuration resolves. The options (`:getenv`, `:config`,
  `:migrations_path`) aim it at a disposable database under test.
  """
  def bootstrap_staging(opts \\ []) when is_list(opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)

    # Read before anything opens a connection, so no configuration mistake can
    # point this command at a database outside staging.
    if getenv.("PATCHBAY_DEPLOYMENT_ROLE") != "staging",
      do: raise("bootstrap-staging requires PATCHBAY_DEPLOYMENT_ROLE to be exactly staging")

    with_release_repo(opts, fn repo ->
      refuse_existing_state!(repo)
      prepare_database!(repo, migrations_directory(opts))
    end)
  end

  @doc false
  # Staging's first deployment and every local database
  # (`Patchbay.LocalDatabaseFixture`) are prepared the same way, in production's
  # order: the tables this repository reads but does not own (the fixture is the
  # only definition of their shape), every shared change this release carries,
  # then this site's own migrations. A relocated schema without the imported
  # history is refused before anything changes.
  def prepare_database!(repo, path \\ migrations_path()) do
    require_imported_history!(repo, path)
    Patchbay.LocalDatabaseFixture.create_shared_tables!()
    apply_shared(repo)
    run_migrations!(repo, path)
  end

  @doc """
  Prints what a deployed database and the release disagree about: the migrations
  the release carries that the database has not applied (`pending:`), the
  versions the database has applied whose file the release does not carry
  (`applied-without-file:`), and the shared changes the release carries that
  their own ledgers do not hold (`shared-pending:`, each as schema and version;
  a deployment is refused while one is listed, and `migrate_shared/1` applies
  them), or `none`.
  It applies nothing, creates nothing, and takes no migration lock. Its options
  are the bootstrap's.
  """
  def pending_migrations(opts \\ []) when is_list(opts) do
    {pending, applied_without_file, shared} =
      with_release_repo(opts, fn repo ->
        {pending, applied_without_file} = disagreements(repo, migrations_directory(opts))
        {pending, applied_without_file, unapplied_shared_migrations(repo)}
      end)

    if pending == [] and applied_without_file == [] and shared == [], do: IO.puts("none")
    if pending != [], do: IO.puts("pending: #{Enum.join(pending, " ")}")

    if applied_without_file != [],
      do: IO.puts("applied-without-file: #{Enum.join(applied_without_file, " ")}")

    if shared != [], do: IO.puts("shared-pending: #{Enum.join(shared, ", ")}")
  end

  @doc """
  Suspends the profile with this public id, for `reason`, as Patchbay's
  console (`Patchbay.Identity.AgentProfile`'s `suspend` action). It can no
  longer sign in on the web, and its live web sign-ins end. Its paired agents
  are refused wherever Patchbay asks whom an agent acts for, its connected
  apps are refused while it stays suspended, and a job disconnects them
  (`Patchbay.Identity.DisconnectApps`). The shared agent check-in, whoami and
  pairing (`regent_agents`) still answer, whoami's list of what the agent may
  do reading as before, and an agent can still finish a payment it made
  before the suspension, whose money has already moved. A wallet signs as a
  wallet author under its own profile, a separate row, so the person's own
  wallet is still accepted there; suspending that wallet's profile refuses
  it. The suspension, its record and its job are saved together. Run on the
  deployment as `/app/bin/suspend-profile <public id> <reason>`.

  It prints what it changed, or why it changed nothing: no profile has that
  id, the profile is already suspended, or the reason is empty or longer than
  500 characters. It starts only the database connection and an Oban that
  queues jobs without running any, so the running site does the work. Its
  options are the bootstrap's: `:config` names another connection.
  """
  def suspend_profile(public_id, reason, opts \\ []) when is_list(opts) do
    with_release_repo(opts, fn _repo ->
      with_inserting_oban(fn ->
        public_id |> Identity.get_profile_by_public_id!(@console) |> suspend(public_id, reason)
      end)
    end)
  end

  defp suspend(nil, public_id, _reason),
    do: IO.puts("No profile has the public id #{public_id}. Nothing changed.")

  defp suspend(profile, public_id, reason) do
    profile
    |> Identity.suspend_profile(reason, actor: @system)
    |> report(public_id, "is suspended.")
  end

  @doc """
  Reinstates the suspended profile with this public id, for `reason`, as
  Patchbay's console. Its old web sign-ins and disconnected apps stay ended:
  the person signs in again and connects their apps again. The reinstatement
  and its record are saved together. Run on the deployment as
  `/app/bin/reinstate-profile <public id> <reason>`.

  It prints what it changed, or why it changed nothing: no profile has that
  id, the profile is not suspended, or the reason is empty or longer than 500
  characters. Its options are the bootstrap's.
  """
  def reinstate_profile(public_id, reason, opts \\ []) when is_list(opts) do
    with_release_repo(opts, fn _repo ->
      public_id |> Identity.get_profile_by_public_id!(@console) |> reinstate(public_id, reason)
    end)
  end

  defp reinstate(nil, public_id, _reason),
    do: IO.puts("No profile has the public id #{public_id}. Nothing changed.")

  defp reinstate(profile, public_id, reason) do
    profile
    |> Identity.reinstate_profile(reason, actor: @system)
    |> report(public_id, "is reinstated.")
  end

  defp report({:ok, _profile}, public_id, done), do: IO.puts("#{public_id} #{done}")

  defp report({:error, %Ash.Error.Invalid{errors: errors}}, public_id, _done),
    do: IO.puts(Enum.map_join(errors, " ", &refusal(&1, public_id)) <> " Nothing changed.")

  # The words for each refusal the profile's suspend and reinstate can give.
  defp refusal(%Ash.Error.Changes.Required{field: :reason}, _public_id),
    do: "The reason is empty."

  defp refusal(%Ash.Error.Changes.InvalidArgument{field: :reason, vars: vars}, _public_id),
    do: "The reason is longer than #{vars[:max]} characters."

  defp refusal(%Ash.Error.Changes.InvalidAttribute{field: :status, message: said}, public_id),
    do: "#{public_id} #{said}."

  @doc """
  Prints the record of the profile with this public id being suspended and
  reinstated (`Patchbay.Identity.StatusChange`), oldest first: the time, which
  of the two, and the reason. It changes nothing. Run on the deployment as
  `/app/bin/status-changes <public id>`. Its options are the bootstrap's.
  """
  def status_changes(public_id, opts \\ []) when is_list(opts) do
    with_release_repo(opts, fn _repo ->
      public_id |> Identity.get_profile_by_public_id!(@console) |> print_status_changes(public_id)
    end)
  end

  defp print_status_changes(nil, public_id),
    do: IO.puts("No profile has the public id #{public_id}.")

  defp print_status_changes(profile, public_id) do
    case Identity.status_changes!(profile.id, actor: @system) do
      [] -> IO.puts("#{public_id} has never been suspended.")
      changes -> Enum.each(changes, &IO.puts(status_change_line(&1)))
    end
  end

  defp status_change_line(%{inserted_at: at, action: action, reason: reason}),
    do: "#{Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")}  #{status_word(action)}  #{reason}"

  defp status_word(:suspend), do: "suspended"
  defp status_word(:reinstate), do: "reinstated"

  # An Oban that only queues jobs, for as long as `fun` runs: no queues, no
  # plugins and never the leader, so the job a suspension queues in its own
  # transaction waits for the running site to take it.
  defp with_inserting_oban(fun) do
    {:ok, _started} = Application.ensure_all_started(:oban)

    {:ok, oban} =
      @app
      |> Application.fetch_env!(Oban)
      |> Keyword.merge(queues: false, plugins: false, peer: false)
      |> Oban.start_link()

    try do
      fun.()
    after
      Supervisor.stop(oban)
    end
  end

  defp disagreements(repo, path) do
    prefix = repo.default_prefix()

    unless table_exists?(repo, prefix, migration_source(repo)),
      do: raise("no schema_migrations table: run bootstrap-staging first")

    migrations =
      Ecto.Migrator.migrations(repo, [path],
        prefix: prefix,
        skip_table_creation: true,
        migration_lock: false
      )

    carried = carried_versions(path)

    {for({:down, version, _name} <- migrations, do: version),
     for({:up, version, _name} <- migrations, version not in carried, do: version)}
  end

  # Ecto names an applied version with no file after a placeholder marker. The
  # set of versions the release actually carries answers the same question
  # without depending on that marker's text.
  defp carried_versions(path) do
    for file <- Path.wildcard(Path.join(path, "*.exs")),
        {version, "_" <> _name} <- [file |> Path.basename() |> Integer.parse()],
        into: MapSet.new(),
        do: version
  end

  defp apply_shared(repo), do: Enum.each(carried_shared(), fn {_, _, m} -> m.up(repo) end)

  # A shared library this site does not carry has no tables it reads or changes.
  defp carried_shared do
    carried = Application.spec(@app, :applications)
    for {app, _schema, _migrator} = shared <- @shared, app in carried, do: shared
  end

  def rollback(repo, version) do
    :ok = Application.ensure_loaded(@app)

    if repo.default_prefix() != "public" and version <= @imported_through do
      raise "Cannot roll back imported history in the shared database"
    end

    with_release_repo([], fn repo ->
      require_imported_history!(repo, migrations_path())

      Ecto.Migrator.run(repo, [migrations_path()], :down,
        to: version,
        prefix: repo.default_prefix()
      )
    end)
  end

  defp run_migrations!(repo, path),
    do: Ecto.Migrator.run(repo, [path], :up, all: true, prefix: repo.default_prefix())

  # An index built while writes go on is left unusable when its build stops
  # part way, and PostgreSQL then never reads it. A build stopped inside a
  # migration already stops the release there, and its migration drops and
  # rebuilds it on the next run; one still unusable afterwards belongs to no
  # pending migration, so only dropping it by hand clears it.
  defp require_usable_indexes!(repo) do
    case Ecto.Adapters.SQL.query!(repo, @unusable_indexes, [repo.default_prefix()]).rows do
      [] ->
        :ok

      names ->
        raise "Unusable indexes left by a stopped build: " <>
                Enum.map_join(names, ", ", &hd/1) <>
                ". No migration rebuilds them; drop each by hand before releasing."
    end
  end

  defp require_imported_history!(repo, path) do
    if repo.default_prefix() != "public" do
      migrations =
        Ecto.Migrator.migrations(repo, [path],
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

  defp refuse_existing_state!(repo) do
    prefix = repo.default_prefix()
    source = migration_source(repo)

    if table_exists?(repo, prefix, source) do
      raise "#{prefix}.#{source} already exists: destroy and recreate the staging database"
    end

    if schema_exists?(repo, @platform_schema) do
      raise "#{@platform_schema} schema already exists: destroy and recreate the staging database"
    end
  end

  defp table_exists?(repo, prefix, table) do
    %{rows: [[exists?]]} = Ecto.Adapters.SQL.query!(repo, @table_exists, [prefix, table])
    exists?
  end

  defp schema_exists?(repo, schema) do
    %{rows: [[exists?]]} = Ecto.Adapters.SQL.query!(repo, @schema_exists, [schema])
    exists?
  end

  defp migration_source(repo), do: repo.config()[:migration_source] || "schema_migrations"

  # Loads the app and starts only its database connection, on the release
  # login unless `:config` names another, for as long as `fun` runs; returns
  # what `fun` returns and puts the Repo's configuration back as it was.
  # with_repo reuses a running Repo, whose existing credentials a changed
  # configuration would not change, so every command needs a fresh release
  # eval. The connection never falls back to the serving one.
  defp with_release_repo(opts, fun) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    :ok = Application.ensure_loaded(@app)

    if Process.whereis(Patchbay.Repo) do
      raise "Migration requires a fresh release eval; the application Repo is already running"
    end

    connection =
      Keyword.get_lazy(opts, :config, fn -> Patchbay.DatabaseConfig.release_config!(getenv) end)

    previous = Application.fetch_env!(@app, Patchbay.Repo)

    Application.put_env(
      @app,
      Patchbay.Repo,
      previous |> Keyword.drop(@connection_keys) |> Keyword.merge(connection)
    )

    try do
      {:ok, result, _started} = Ecto.Migrator.with_repo(Patchbay.Repo, fun)
      result
    after
      Application.put_env(@app, Patchbay.Repo, previous)
    end
  end

  defp migrations_directory(opts),
    do: Keyword.get_lazy(opts, :migrations_path, &migrations_path/0)

  defp migrations_path, do: Application.app_dir(@app, "priv/repo/migrations")
end
