defmodule PatchbayWeb.HealthController do
  @moduledoc """
  Unauthenticated deployment probe.

  Answers 200 only when the database responds and every migration has run, so a
  broken release fails its platform health check instead of serving a room it
  cannot read. Everything else it reports is operational context: the running
  version and which generation mode this machine is in. The API key is never
  read into the response.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Config

  # A release carries a fixed set of migration files, so "everything has run"
  # cannot become false again while this node is up. Caching it keeps a polled
  # probe off the migration table, where it would otherwise contend with the
  # migration a deploy is running.
  @migrations_cache_key {__MODULE__, :migrations_status}

  def show(conn, _params) do
    database = database_status()
    migrations = migrations_status(database)
    healthy? = database == "ok" and migrations == "current"

    conn
    |> put_status(if healthy?, do: :ok, else: :service_unavailable)
    |> json(%{
      status: if(healthy?, do: "ok", else: "error"),
      version: version(),
      database: database,
      migrations: migrations,
      live_inference_configured: Config.live_inference_configured?(),
      demo_fallback_enabled: Config.demo_fallback?()
    })
  end

  defp database_status do
    case Ecto.Adapters.SQL.query(Patchbay.Repo, "SELECT 1", []) do
      {:ok, _result} -> "ok"
      {:error, reason} -> failed("database is unreachable", reason)
    end
  rescue
    error -> failed("database probe raised", error)
  end

  defp migrations_status("ok") do
    case :persistent_term.get(@migrations_cache_key, nil) do
      nil -> check_migrations()
      cached -> cached
    end
  end

  defp migrations_status(_database), do: "unknown"

  defp check_migrations do
    repo = Patchbay.Repo

    migrations =
      Ecto.Migrator.migrations(repo, [Ecto.Migrator.migrations_path(repo)],
        skip_table_creation: true,
        migration_lock: false
      )

    if Enum.any?(migrations, &match?({:down, _version, _name}, &1)) do
      "pending"
    else
      :persistent_term.put(@migrations_cache_key, "current")
      "current"
    end
  rescue
    error -> failed("migration status is unreadable", error)
  end

  defp failed(message, reason) do
    Logger.error("health check: #{message}: #{inspect(reason)}")
    "error"
  end

  defp version do
    :patchbay |> Application.spec(:vsn) |> to_string()
  end
end
