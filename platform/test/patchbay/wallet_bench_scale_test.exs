defmodule Patchbay.WalletBench.ScaleTest do
  @moduledoc """
  The minute's read of the whole bench (`Patchbay.WalletBench.Board`) must
  stay cheap at production's size and beyond, read through views shaped as
  Techtree's (`Patchbay.TechtreeBenchViews`), and a visit to the board, a
  pair's page or the sitemap must then read nothing from those views.
  Release v284 named each check by its newest run with a lookup into the runs
  view for every check: on production's bench the page timed out after 15
  seconds and held database connections, and on this bench each page took
  four to five seconds. Before the bench was shared, every visit read the
  views: about 400 ms of database time.
  """

  # Techtree's views replace two shared tables until the test ends, and the
  # bench read is shared by the whole run.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Repo
  alias Patchbay.WalletBench.Board
  alias Patchbay.WalletBench.Matrix
  alias Patchbay.WalletBench.Sets

  # 2,000 finished attempts: 5,000 runs and 33,000 checks, from 12 agents by
  # 10 wallets.
  @attempts 2_000

  # What the read and each visit may cost in the BEAM's own count of work
  # (reductions, across every process), which stays the same however busy
  # the machine is. Time did not: the read took about 400 ms on a quiet
  # machine and up to 1.4 s with other checks running beside it. The read
  # costs about 48 million and the costliest visit, a filtered board, about
  # 1.6 million; a visit that read the bench itself would cost about as much
  # as the read. The database's part is bounded by the read sending one query
  # to each of the seven views and nothing for each row.
  @read_reductions 100_000_000
  @visit_reductions 4_000_000

  setup do
    Patchbay.TechtreeBenchViews.install!(Repo, @attempts)

    Repo.query!("""
    INSERT INTO techtree_app.wallet_bench_roster (kind, id, name)
    SELECT 'harness', 'H' || n, 'Agent ' || n FROM generate_series(1, 12) n
    UNION ALL
    SELECT 'wallet', 'W' || n, 'Wallet ' || n FROM generate_series(1, 10) n
    """)

    Repo.query!(
      "INSERT INTO techtree_app.wallet_bench_notes (key, text) SELECT o, o || ': meaning.' FROM unnest($1::text[]) o",
      [Matrix.outcomes()]
    )

    Repo.query!("""
    INSERT INTO techtree_app.wallet_bench_pair_summary
      (set_id, harness_id, wallet_id, grid, current, runs, successes, caveat_runs, proof_kind,
       last_run_at)
    SELECT set_id, min(harness_id), min(wallet_id), min(grid), true, count(*), count(*), 0,
           'judge', max(finished_at)
    FROM techtree_app.wallet_bench_results GROUP BY set_id
    """)

    :ok
  end

  test "the minute's read stays cheap on a production-sized bench, and a visit reads no view",
       %{conn: conn} do
    assert %{rows: [[5_000, 33_000]]} =
             Repo.query!("""
             SELECT (SELECT count(*) FROM techtree_app.wallet_bench_results)::integer,
                    (SELECT count(*) FROM techtree_app.wallet_bench_checks)::integer
             """)

    on_exit(&PatchbayTest.SharedBench.forget/0)
    Req.Test.stub(Patchbay.WalletBench.PublicRun, &Plug.Conn.send_resp(&1, 404, ""))

    {read, {:ok, views}} = work(fn -> PatchbayTest.SharedBench.views_read(&Board.refresh/0) end)
    assert read < @read_reductions, "the read cost #{read} reductions"
    assert length(views) == 7, "the read sent #{length(views)} queries to the views"

    {:ok, matrix, _read} = Board.board(%{}, Matrix.grids())
    {:ok, key, _read} = Board.method()

    # Both pages name the same checks, every grid's in full.
    assert Enum.map(key.grids, &length(&1.criteria)) == [9, 9, 5, 5, 5]
    assert Enum.map(key.grids, & &1.criteria) == Enum.map(matrix.grids, & &1.criteria)

    [%{id: model} | _] = matrix.options["model"]

    for path <- [
          "/wallet-bench",
          "/wallet-bench?test=wallet&model=#{model}",
          "/api/wallet-bench",
          "/wallet-bench/H1/W1",
          "/api/wallet-bench/H1/W1?test=wallet&model=#{model}",
          "/sitemap.xml"
        ] do
      {visit, {conn, views}} =
        work(fn -> PatchbayTest.SharedBench.views_read(fn -> get(conn, path) end) end)

      assert conn.status == 200, path
      assert views == [], "#{path} read #{inspect(views)}"
      assert visit < @visit_reductions, "#{path} cost #{visit} reductions"
    end

    # Every run here has the one model, so filtering by it leaves each
    # test's board as it is without a filter.
    filters = %{"model" => model}
    assert Sets.valid_filters?(filters, matrix.options)

    for grid <- matrix.grids do
      assert {:ok, %{grids: [filtered]}, _read} = Board.board(filters, [grid.grid])
      assert filtered == grid
    end
  end

  # The work `fun` does, counted by the BEAM in reductions across every
  # process, with its result.
  defp work(fun) do
    :erlang.statistics(:exact_reductions)
    result = fun.()
    {_total, done} = :erlang.statistics(:exact_reductions)
    {done, result}
  end
end
