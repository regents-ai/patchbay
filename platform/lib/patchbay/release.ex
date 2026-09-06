defmodule Patchbay.Release do
  @moduledoc """
  Database tasks for the packaged release, where Mix is not available.
  """

  @app :patchbay
  # Last migration already present in the preserved source. Its predecessors
  # contain public-qualified references and must never replay after relocation.
  @imported_through 20_260_904_074_137

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        with_migration_repo(repo, fn repo ->
          require_imported_history!(repo)
          Ecto.Migrator.run(repo, :up, all: true, prefix: repo.default_prefix())
        end)
    end
  end

  def rollback(repo, version) do
    load_app()

    if repo.default_prefix() != "public" and version <= @imported_through do
      raise "Cannot roll back imported history in the shared database"
    end

    {:ok, _result, _apps} =
      with_migration_repo(repo, fn repo ->
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

  @doc """
  Select the explicitly supplied migration connection, retaining schema and transport settings.
  Release commands never fall back to the application's runtime credentials.
  """
  def migration_config!(repo, getenv \\ &System.get_env/1) do
    url = getenv.("DATABASE_DIRECT_URL")

    connection =
      try do
        %URI{scheme: scheme, host: host, userinfo: userinfo, query: query, fragment: nil} =
          URI.new!(url || "")

        true = scheme in ["postgres", "postgresql"] and is_binary(host) and host != ""
        true = query in [nil, ""]
        [username, password] = String.split(userinfo || "", ":", parts: 2)
        true = String.trim(username) != "" and String.trim(password) != ""
        parsed = Ecto.Repo.Supervisor.parse_url(url) |> Keyword.put_new(:port, 5432)
        true = Keyword.get(parsed, :port, 5432) in 1..65_535
        true = String.trim(Keyword.fetch!(parsed, :database)) != ""
        parsed
      rescue
        _error -> :invalid_url
      end

    if connection == :invalid_url do
      raise "DATABASE_DIRECT_URL must be a PostgreSQL URL with credentials and no query or fragment"
    end

    @app
    |> Application.fetch_env!(repo)
    |> Keyword.drop([
      :url,
      :hostname,
      :port,
      :socket,
      :socket_dir,
      :endpoints,
      :username,
      :password,
      :database
    ])
    |> Keyword.merge(connection)
  end

  # with_repo reuses a running Repo. Changing its configuration would not change
  # those existing credentials, so migration commands require a fresh release eval.
  defp with_migration_repo(repo, fun) do
    if Process.whereis(repo) do
      raise "Migration requires a fresh release eval; the application Repo is already running"
    end

    previous = Application.fetch_env!(@app, repo)
    Application.put_env(@app, repo, migration_config!(repo))

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
