defmodule Patchbay.WalletBench.ScaleTest do
  @moduledoc """
  The board and How the bench works read the whole bench on every visit, so
  both must stay quick at production's size and beyond, read through views
  shaped as Techtree's (`Patchbay.TechtreeBenchViews`). Release v284 named each
  check by its newest run with a lookup into the runs view for every check:
  on production's bench the page timed out after 15 seconds and held database
  connections, and on this bench each page took four to five seconds.
  """

  # Techtree's views replace two shared tables until the test ends.
  use Patchbay.DataCase, async: false

  alias Patchbay.WalletBench.Matrix

  # 2,000 finished attempts: 5,000 runs and 33,000 checks, from 12 agents by
  # 10 wallets.
  @attempts 2_000

  # Generous, so a busy machine never fails it: the board takes about half a
  # second here and How the bench works about a fifth.
  @bound_microseconds 1_000_000

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

  test "the board and How the bench works read a production-sized bench well inside a second" do
    assert %{rows: [[5_000, 33_000]]} =
             Repo.query!("""
             SELECT (SELECT count(*) FROM techtree_app.wallet_bench_results)::integer,
                    (SELECT count(*) FROM techtree_app.wallet_bench_checks)::integer
             """)

    {board_us, {:ok, matrix}} = :timer.tc(fn -> Matrix.read() end)
    {key_us, {:ok, key}} = :timer.tc(fn -> Matrix.key() end)

    assert board_us < @bound_microseconds, "the board took #{div(board_us, 1000)} ms"
    assert key_us < @bound_microseconds, "How the bench works took #{div(key_us, 1000)} ms"

    # Both pages name the same checks, every grid's in full.
    assert Enum.map(key.grids, &length(&1.criteria)) == [9, 9, 5, 5, 5]
    assert Enum.map(key.grids, & &1.criteria) == Enum.map(matrix.grids, & &1.criteria)
  end
end
