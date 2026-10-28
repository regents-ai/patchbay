defmodule PatchbayWeb.WalletBenchMethodTest do
  @moduledoc "How the bench works: each test's checks and each result's meaning, read without any run."

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.WalletBench
  alias Patchbay.WalletBench.Matrix

  # One judged check of one run, as Techtree publishes it.
  defp check!(grid, criterion_id, criterion, attempt_id \\ Ecto.UUID.generate()) do
    Patchbay.Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_checks
        (attempt_id, grid, criterion_id, harness_id, wallet_id, run, criterion, result)
      VALUES ($1, $2, $3, 'H1', 'W1', 1, $4, 'true')
      """,
      [Ecto.UUID.dump!(attempt_id), grid, criterion_id, criterion]
    )
  end

  # One run of the install test, finished at `finished_at`.
  defp run!(finished_at) do
    attempt_id = Ecto.UUID.generate()

    Patchbay.Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_results
        (attempt_id, grid, harness_id, wallet_id, run, outcome, decided_by, turns, run_url,
         set_versions, set_id, finished_at)
      VALUES ($1, 'install', 'H1', 'W1', 1, 'PASS', 'T1a', '[]', 'https://techtree.sh/run',
              '{}', 'set', $2)
      """,
      [Ecto.UUID.dump!(attempt_id), finished_at]
    )

    attempt_id
  end

  # The rest of what the board reads: one agent, one wallet, the runs' set and
  # what a pass means.
  defp board! do
    Patchbay.Repo.query!("""
    INSERT INTO techtree_app.wallet_bench_roster (kind, id, name)
    VALUES ('harness', 'H1', 'Agent'), ('wallet', 'W1', 'Wallet')
    """)

    Patchbay.Repo.query!("""
    INSERT INTO techtree_app.wallet_bench_pair_summary
      (set_id, harness_id, wallet_id, grid, current, runs, successes, caveat_runs, proof_kind,
       last_run_at)
    VALUES ('set', 'H1', 'W1', 'install', true, 2, 2, 0, 'judge', '2026-10-27 12:00:00')
    """)

    Patchbay.Repo.query!(
      "INSERT INTO techtree_app.wallet_bench_notes (key, text) VALUES ('PASS', 'Pass: every check held.')"
    )
  end

  test "lists each test's checks once, in order, and what each result means", %{conn: conn} do
    # Three runs of the install test judged on the same two checks.
    for _run <- 1..3 do
      check!("install", "C2", "The wallet tool reports its version.")
      check!("install", "C1", "The agent installs the wallet tool.")
    end

    Patchbay.Repo.query!(
      "INSERT INTO techtree_app.wallet_bench_notes (key, text) VALUES ('PASS', 'Pass: every check held.')"
    )

    page = conn |> get("/wallet-bench/how-it-works") |> html_response(200)
    assert page =~ "The agent installs the wallet tool."
    assert page =~ "Pass: every check held."

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/wallet-bench/how-it-works")
      |> response(200)

    assert markdown =~
             "### Install\n\n1. The agent installs the wallet tool.\n2. The wallet tool reports its version.\n\n### Make a wallet\n\nListed once this test has run."

    assert markdown =~ "- `PASS`: Pass: every check held."
  end

  test "a check reworded between runs is named by its newest run's wording, here and on the board",
       %{conn: conn} do
    newer = run!(~N[2026-10-27 12:00:00])
    older = run!(~N[2026-10-20 12:00:00])
    # The older wording is written first, so a read that takes the first row it
    # finds would name it.
    check!("install", "C1", "The wallet tool prints a version.", older)
    check!("install", "C1", "The wallet tool answers with its version number.", newer)
    board!()

    assert {:ok, [%{criterion: "The wallet tool answers with its version number."}]} =
             WalletBench.list_criteria()

    page = conn |> get("/wallet-bench/how-it-works") |> html_response(200)
    assert page =~ "The wallet tool answers with its version number."
    refute page =~ "The wallet tool prints a version."

    board = conn |> get("/wallet-bench?test=install") |> html_response(200)
    assert board =~ "The wallet tool answers with its version number."
    refute board =~ "The wallet tool prints a version."

    {:ok, %{grids: grids}} = Matrix.read()
    install = Enum.find(grids, &(&1.grid == "install"))

    assert install.criteria == [
             %{id: "C1", criterion: "The wallet tool answers with its version number."}
           ]
  end
end
