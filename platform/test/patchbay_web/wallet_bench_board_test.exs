defmodule PatchbayWeb.WalletBenchBoardTest do
  @moduledoc """
  The Wallet Bench read once a minute and shared with every visitor
  (`Patchbay.WalletBench.Board`): a visit reads nothing from Techtree's views,
  filters apply to the shared rows in memory, a failed read keeps the last
  board on show and says so, and a site that has not read the bench yet
  answers 503 instead of failing.
  """

  # One shared reading for the whole run, and a producer started here.
  use PatchbayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Patchbay.Repo
  alias Patchbay.WalletBench.Board
  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.Sets
  alias PatchbayTest.SharedBench

  setup do
    SharedBench.forget()
    on_exit(&SharedBench.forget/0)

    Repo.query!("""
    INSERT INTO techtree_app.wallet_bench_roster (kind, id, name)
    VALUES ('harness', 'H1', 'Agent One'), ('wallet', 'W1', 'Wallet One'), ('wallet', 'W2', 'Wallet Two')
    """)

    Repo.query!(
      "INSERT INTO techtree_app.wallet_bench_notes (key, text) SELECT o, o || ': meaning.' FROM unnest($1::text[]) o",
      [Matrix.outcomes()]
    )

    run!("W1", "model-a", "PASS", ~N[2026-10-20 12:00:00])
    run!("W2", "model-b", "FAILED_TECHNICAL", ~N[2026-10-21 12:00:00])
    :ok
  end

  # One install run of H1 with `wallet` on `model`, in a set of its own.
  defp run!(wallet, model, outcome, finished_at) do
    set_id = "H1-#{wallet}-#{model}"

    Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_results
        (attempt_id, grid, harness_id, wallet_id, run, outcome, decided_by, turns, run_url,
         set_versions, set_id, finished_at)
      VALUES ($1, 'install', 'H1', $2, 1, $3, 'T1a', '[]', 'https://techtree.sh/run',
              jsonb_build_object('model', $4::text), $5, $6)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), wallet, outcome, model, set_id, finished_at]
    )

    Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_pair_summary
        (set_id, harness_id, wallet_id, grid, current, runs, successes, caveat_runs, proof_kind,
         last_run_at)
      VALUES ($1, 'H1', $2, 'install', true, 1, 1, 0, 'judge', $3)
      """,
      [set_id, wallet, finished_at]
    )
  end

  test "a visit reads no view, says when the bench was read, and filters in memory", %{
    conn: conn
  } do
    SharedBench.share!()
    model_b = Sets.token("model-b")

    for path <- [
          "/wallet-bench?test=install",
          "/wallet-bench?test=install&model=#{model_b}",
          "/api/wallet-bench?model=#{model_b}",
          "/wallet-bench/how-it-works"
        ] do
      {conn, views} = SharedBench.views_read(fn -> get(conn, path) end)
      assert conn.status == 200, path
      assert views == [], "#{path} read #{inspect(views)}"
      # Each visit counts against the address's share of reads a minute.
      assert [~s("reads") <> _] = get_resp_header(conn, "ratelimit-policy")
    end

    page = conn |> get("/wallet-bench?test=install") |> html_response(200)
    assert page =~ "Results read from Techtree just now."
    assert page =~ "Wallet One" and page =~ "Wallet Two"

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/wallet-bench?test=install")
      |> response(200)

    assert markdown =~ "Results read from Techtree just now."

    # The filter leaves only Wallet Two's run, as a read of the views would.
    filtered =
      conn |> get("/api/wallet-bench?test=install&model=#{model_b}") |> json_response(200)

    assert filtered["tested"] == 1
    latest = Map.new(filtered["squares"], &{&1["wallet_id"], &1["latest_attempt"]})
    assert %{"W1" => nil, "W2" => %{"outcome" => "FAILED_TECHNICAL"}} = latest

    # With a filter, only the test shown is built, and a wallet with runs in
    # no other test is still shown.
    assert {:ok, %{grids: [install], wallets: wallets}, _read} =
             Board.board(%{"model" => model_b}, ["install"])

    assert install.grid == "install" and Enum.map(wallets, & &1.id) == ["W1", "W2"]

    # "Any recorded version" is no filter: the board built once answers.
    any = conn |> get("/api/wallet-bench?test=install&model=&harness=") |> json_response(200)
    assert any["filters"] == %{}
    assert any == conn |> get("/api/wallet-bench?test=install") |> json_response(200)

    # A filter naming no recorded version is still not found.
    assert_error_sent 404, fn -> get(conn, "/wallet-bench?model=#{Sets.token("model-z")}") end
  end

  test "a run that finishes shows on the next read, not before" do
    SharedBench.share!()
    {:ok, before, _read} = Board.board(%{}, ["install"])

    run!("W1", "model-c", "FAILED_SAFETY", ~N[2026-10-28 12:00:00])
    assert {:ok, ^before, _read} = Board.board(%{}, ["install"])

    :ok = Board.refresh()
    {:ok, board, _read} = Board.board(%{}, ["install"])
    install = Enum.find(board.grids, &(&1.grid == "install"))
    assert install.squares[{"H1", "W1"}].display_run.outcome == "FAILED_SAFETY"
  end

  test "a failed read keeps the last board on show, marked, and logs one warning", %{conn: conn} do
    SharedBench.share!()
    {:ok, board, %{at: at, degraded?: false}} = Board.board(%{}, ["install"])

    # Techtree's roster view goes missing for one read, then comes back.
    Repo.query!("ALTER TABLE techtree_app.wallet_bench_roster RENAME TO wallet_bench_roster_gone")
    {failed, log} = with_log(&Board.refresh/0)
    Repo.query!("ALTER TABLE techtree_app.wallet_bench_roster_gone RENAME TO wallet_bench_roster")

    assert {:error, _reason} = failed
    assert [_one] = Regex.scan(~r/\[warning\].*Wallet Bench/, log)
    assert log =~ ~s|relation "techtree_app.wallet_bench_roster" does not exist|
    refute log =~ "Bread Crumbs"
    assert {:ok, ^board, %{at: ^at, degraded?: true}} = Board.board(%{}, ["install"])
    assert {:ok, _method, %{degraded?: true}} = Board.method()

    page = conn |> get("/wallet-bench?test=install") |> html_response(200)
    assert page =~ "The latest read got no answer, so these are the last results it gave."
    assert page =~ "Wallet Two"

    :ok = Board.refresh()
    assert {:ok, ^board, %{degraded?: false}} = Board.board(%{}, ["install"])
  end

  test "a view slower than the limit is cancelled by Postgres, which frees the connection" do
    SharedBench.share!()
    {:ok, board, _read} = Board.board(%{}, ["install"])

    # Techtree's notes view takes three seconds; the test's limit is one.
    Repo.query!("ALTER TABLE techtree_app.wallet_bench_notes RENAME TO wallet_bench_notes_kept")

    Repo.query!("""
    CREATE VIEW techtree_app.wallet_bench_notes AS
    SELECT key, text FROM techtree_app.wallet_bench_notes_kept, pg_sleep(3)
    """)

    {{elapsed, failed}, log} = with_log(fn -> :timer.tc(&Board.refresh/0) end)

    Repo.query!("DROP VIEW techtree_app.wallet_bench_notes")
    Repo.query!("ALTER TABLE techtree_app.wallet_bench_notes_kept RENAME TO wallet_bench_notes")

    assert {:error, _reason} = failed
    assert elapsed < 2_500_000, "the read took #{div(elapsed, 1000)} ms"
    assert log =~ "canceling statement due to statement timeout"
    refute log =~ "Bread Crumbs"

    # Nothing is left running on the server, and the last board stays.
    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*)::integer FROM pg_stat_activity
             WHERE state = 'active' AND query LIKE '%pg_sleep(3)%' AND pid <> pg_backend_pid()
             """)

    assert {:ok, ^board, %{degraded?: true}} = Board.board(%{}, ["install"])
  end

  test "before the first read the board answers 503 at every door, and the producer reads as it starts",
       %{conn: conn} do
    assert Board.board(%{}, ["install"]) == :unread

    html = conn |> get("/wallet-bench") |> html_response(503)
    assert html =~ "This page is not ready yet."
    assert get_resp_header(get(conn, "/wallet-bench"), "retry-after") == ["60"]

    assert %{"error" => %{"code" => "not_ready"}} =
             conn |> get("/api/wallet-bench") |> json_response(503)

    assert conn |> get("/wallet-bench/how-it-works") |> html_response(503) =~ "not ready yet"

    assert conn
           |> put_req_header("accept", "text/markdown")
           |> get("/wallet-bench")
           |> response(503) =~
             "# This page is not ready yet."

    assert {:service_unavailable, %{"error" => %{"code" => "not_ready"}}} =
             PatchbayWeb.WalletBenchController.read_wallet_bench(%{})
             |> then(fn {status, body} -> {status, Jason.decode!(Jason.encode!(body))} end)

    # The producer's first read happens inside its start, so the board is
    # there once the site begins to serve.
    start_supervised!(Board)
    assert {:ok, _board, %{degraded?: false}} = Board.board(%{}, ["install"])
    assert conn |> get("/wallet-bench?test=install") |> html_response(200) =~ "Wallet Two"

    # The minute's scheduled heal reaches the producer, which reads again.
    run!("W1", "model-c", "FAILED_SAFETY", ~N[2026-10-28 12:00:00])
    assert :ok = perform_job(Patchbay.SharedReading.Heal, %{kind: "wallet_bench"})
    :sys.get_state(Board)

    {:ok, board, _read} = Board.board(%{}, ["install"])
    install = Enum.find(board.grids, &(&1.grid == "install"))
    assert install.squares[{"H1", "W1"}].display_run.outcome == "FAILED_SAFETY"
  end

  defp perform_job(worker, args), do: Oban.Testing.perform_job(worker, args, repo: Repo)
end
