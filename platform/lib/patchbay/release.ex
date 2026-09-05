defmodule Patchbay.Release do
  @moduledoc """
  Database tasks for the packaged release, where Mix is not available.
  """

  @app :patchbay

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_loaded(@app)
  end
end
