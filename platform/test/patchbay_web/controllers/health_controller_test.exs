defmodule PatchbayWeb.HealthControllerTest do
  # The migration answer is cached node-wide, so these run one at a time.
  use PatchbayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # The controller caches a fully migrated database for the life of the node.
  @migrations_cache_key {PatchbayWeb.HealthController, :migrations_status}

  setup do
    :persistent_term.erase(@migrations_cache_key)
    on_exit(fn -> :persistent_term.erase(@migrations_cache_key) end)
    :ok
  end

  test "answers 200 once the database is migrated", %{conn: conn} do
    conn = get(conn, ~p"/webmcp/health")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "database" => "ok",
             "migrations" => "current"
           }
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

  test "/healthz answers ok in plain text, uncached, once the database answers", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
    assert response_content_type(conn, :text) =~ "text/plain"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "/healthz answers 503 and logs when the database cannot be reached", %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)

    {conn, log} = with_log(fn -> get(conn, ~p"/healthz") end)

    assert response(conn, 503) == "unavailable"
    assert log =~ "health check: database is unreachable"
  end

  test "/api/v1/health answers 503 and logs when the database cannot be reached", %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)

    {conn, log} = with_log(fn -> get(conn, ~p"/api/v1/health") end)

    assert %{"error" => %{"code" => "unavailable"}} = json_response(conn, 503)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert log =~ "health check: database is unreachable"
  end
end
