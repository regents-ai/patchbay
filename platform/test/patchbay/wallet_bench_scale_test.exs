defmodule Patchbay.WalletBench.ScaleTest do
  @moduledoc """
  The minute's read of the whole bench (`Patchbay.WalletBench.Board`) must
  stay quick at production's size and beyond, read through views shaped as
  Techtree's (`Patchbay.TechtreeBenchViews`), and a visit to the board must
  then read nothing from those views. Release v284 named each check by its
  newest run with a lookup into the runs view for every check: on
  production's bench the page timed out after 15 seconds and held database
  connections, and on this bench each page took four to five seconds. Before
  the bench was shared, every visit read the views: about 400 ms of database time.
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

  # Generous, so a busy machine never fails it: the read takes about 400 ms
  # here, and a visit to the board about 20 ms with a filter.
  @bound_microseconds 1_000_000
  @visit_microseconds 250_000

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

  test "the minute's read takes well inside a second on a production-sized bench, and a visit reads no view",
       %{conn: conn} do
    assert %{rows: [[5_000, 33_000]]} =
             Repo.query!("""
             SELECT (SELECT count(*) FROM techtree_app.wallet_bench_results)::integer,
                    (SELECT count(*) FROM techtree_app.wallet_bench_checks)::integer
             """)

    on_exit(&PatchbayTest.SharedBench.forget/0)
    {read_us, :ok} = :timer.tc(&Board.refresh/0)
    assert read_us < @bound_microseconds, "the read took #{div(read_us, 1000)} ms"

    {:ok, matrix, _read} = Board.board(%{}, Matrix.grids())
    {:ok, key, _read} = Board.method()

    # Both pages name the same checks, every grid's in full.
    assert Enum.map(key.grids, &length(&1.criteria)) == [9, 9, 5, 5, 5]
    assert Enum.map(key.grids, & &1.criteria) == Enum.map(matrix.grids, & &1.criteria)

    [%{id: model} | _] = matrix.options["model"]

    for path <- ["/wallet-bench", "/wallet-bench?test=wallet&model=#{model}", "/api/wallet-bench"] do
      {visit_us, {conn, views}} =
        :timer.tc(fn -> PatchbayTest.SharedBench.views_read(fn -> get(conn, path) end) end)

      assert conn.status == 200
      assert views == [], "#{path} read #{inspect(views)}"
      assert visit_us < @visit_microseconds, "#{path} took #{div(visit_us, 1000)} ms"
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
end
