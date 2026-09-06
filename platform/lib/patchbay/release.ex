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
        Ecto.Migrator.with_repo(repo, fn repo ->
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
      Ecto.Migrator.with_repo(repo, fn repo ->
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_loaded(@app)
  end
end
