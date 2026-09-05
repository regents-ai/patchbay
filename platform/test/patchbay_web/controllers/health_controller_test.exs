defmodule PatchbayWeb.HealthControllerTest do
  # The probe reads OPENAI_API_KEY and PATCHBAY_DEMO_FALLBACK from the
  # environment, which is process-wide.
  use PatchbayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # The controller caches a fully migrated database for the life of the node.
  @migrations_cache_key {PatchbayWeb.HealthController, :migrations_status}

  setup do
    previous_key = System.get_env("OPENAI_API_KEY")
    previous_fallback = System.get_env("PATCHBAY_DEMO_FALLBACK")
    previous_configured_fallback = Application.get_env(:patchbay, :demo_fallback)

    System.delete_env("OPENAI_API_KEY")
    System.delete_env("PATCHBAY_DEMO_FALLBACK")
    Application.put_env(:patchbay, :demo_fallback, false)
    :persistent_term.erase(@migrations_cache_key)

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", previous_key)
      restore_env("PATCHBAY_DEMO_FALLBACK", previous_fallback)
      :persistent_term.erase(@migrations_cache_key)

      if is_nil(previous_configured_fallback) do
        Application.delete_env(:patchbay, :demo_fallback)
      else
        Application.put_env(:patchbay, :demo_fallback, previous_configured_fallback)
      end
    end)

    :ok
  end

  test "answers 200 with the running version once the database is migrated", %{conn: conn} do
    conn = get(conn, ~p"/webmcp/health")

    assert %{
             "status" => "ok",
             "version" => version,
             "database" => "ok",
             "migrations" => "current",
             "live_inference_configured" => false,
             "demo_fallback_enabled" => false
           } = json_response(conn, 200)

    assert version == to_string(Application.spec(:patchbay, :vsn))
  end

  test "reports live inference as configured without exposing the key", %{conn: conn} do
    System.put_env("OPENAI_API_KEY", "sk-test-not-a-real-key")

    conn = get(conn, ~p"/webmcp/health")

    assert json_response(conn, 200)["live_inference_configured"] == true
    refute conn.resp_body =~ "sk-test-not-a-real-key"
  end

  test "reports the demo fallback when it is enabled", %{conn: conn} do
    System.put_env("PATCHBAY_DEMO_FALLBACK", "true")

    conn = get(conn, ~p"/webmcp/health")

    assert json_response(conn, 200)["demo_fallback_enabled"] == true
  end

  test "answers 503 while a migration is still pending", %{conn: conn} do
    Ecto.Adapters.SQL.query!(
      Patchbay.Repo,
      "DELETE FROM schema_migrations WHERE version = (SELECT MAX(version) FROM schema_migrations)",
      []
    )

    conn = get(conn, ~p"/webmcp/health")

    assert %{"status" => "error", "database" => "ok", "migrations" => "pending"} =
             json_response(conn, 503)
  end

  test "a migrated database is only read once per node", %{conn: conn} do
    get(conn, ~p"/webmcp/health")

    # The cached answer survives the migration row disappearing underneath it,
    # which is what keeps a polled probe off the migration table.
    Ecto.Adapters.SQL.query!(
      Patchbay.Repo,
      "DELETE FROM schema_migrations WHERE version = (SELECT MAX(version) FROM schema_migrations)",
      []
    )

    assert json_response(get(conn, ~p"/webmcp/health"), 200)["migrations"] == "current"
  end

  test "answers 503 and logs when the database cannot be reached", %{conn: conn} do
    # Take the shared sandbox connection away so the probe cannot reach the
    # database from this process.
    Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)

    {conn, log} = with_log(fn -> get(conn, ~p"/webmcp/health") end)

    assert %{"status" => "error", "database" => "error", "migrations" => "unknown"} =
             json_response(conn, 503)

    assert log =~ "health check: database is unreachable"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
