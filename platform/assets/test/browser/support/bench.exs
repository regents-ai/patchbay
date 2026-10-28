# The browser walk's Agent Wallet Bench, on the walk's own local database: the
# tables Techtree publishes (PatchbayDev.WalletBenchTables, the ones the tests make
# too) and a small board of four agents and three wallets, one install run each,
# so the board has rows under its open Filter panel and How the bench works has
# its two cards. Run by serve.sh before the server starts; PatchbayDev.WalkDatabase
# refuses any database but the walk's local one.
alias Patchbay.Repo

PatchbayDev.WalkDatabase.own!(Repo.config())
PatchbayDev.WalletBenchTables.create!(Repo)

harnesses = for n <- 1..4, do: {"H#{n}", "Agent #{n}"}
wallets = for n <- 1..3, do: {"W#{n}", "Wallet #{n}"}

for {kind, entries} <- [{"harness", harnesses}, {"wallet", wallets}], {id, name} <- entries do
  Repo.query!(
    "INSERT INTO techtree_app.wallet_bench_roster (kind, id, name, version) VALUES ($1, $2, $3, '1.0.0')",
    [kind, id, name]
  )
end

for outcome <- Patchbay.WalletBench.Matrix.outcomes() do
  Repo.query!("INSERT INTO techtree_app.wallet_bench_notes (key, text) VALUES ($1, $2)", [
    outcome,
    "#{outcome}: Techtree's word for this result."
  ])
end

finished = ~N[2026-10-27 12:00:00]

for {harness, _name} <- harnesses, {wallet, _name} <- wallets do
  set_id = "#{harness}-#{wallet}"
  attempt_id = Ecto.UUID.dump!(Ecto.UUID.generate())

  Repo.query!(
    """
    INSERT INTO techtree_app.wallet_bench_results
      (attempt_id, grid, harness_id, wallet_id, run, outcome, decided_by, turns, run_url,
       versions, set_versions, set_id, finished_at)
    VALUES ($1, 'install', $2, $3, 1, 'PASS', 'T1a', '[]', 'https://techtree.sh/runs/walk',
            $4, $4, $5, $6)
    """,
    [
      attempt_id,
      harness,
      wallet,
      %{"harness" => "1.0.0", "wallet" => "1.0.0", "model" => "walk-model", "protocol" => "v2"},
      set_id,
      finished
    ]
  )

  Repo.query!(
    """
    INSERT INTO techtree_app.wallet_bench_pair_summary
      (set_id, harness_id, wallet_id, grid, current, runs, successes, caveat_runs, proof_kind,
       last_run_at)
    VALUES ($1, $2, $3, 'install', true, 1, 1, 0, 'judge', $4)
    """,
    [set_id, harness, wallet, finished]
  )

  for n <- 1..9 do
    Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_checks
        (attempt_id, grid, criterion_id, harness_id, wallet_id, run, criterion, result)
      VALUES ($1, 'install', $2, $3, $4, 1, $5, 'true')
      """,
      [attempt_id, "C#{n}", harness, wallet, "Install check #{n} held."]
    )
  end
end
