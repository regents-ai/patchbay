defmodule PatchbayDev.WalletBenchTables do
  @moduledoc """
  Techtree owns and publishes the Agent Wallet Bench in the shared database
  (`Patchbay.WalletBench`). A database made on this machine for the tests
  (test/test_helper.exs) or the browser walk
  (assets/test/browser/support/bench.exs) has only this copy of the columns
  Patchbay reads.
  """

  @tables [
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_results (
      attempt_id uuid NOT NULL,
      grid text NOT NULL,
      harness_id text NOT NULL,
      wallet_id text NOT NULL,
      run integer NOT NULL,
      outcome text,
      outcome_detail text,
      plain_file text,
      decided_by text,
      turns jsonb NOT NULL,
      run_url text NOT NULL,
      versions jsonb,
      set_versions jsonb NOT NULL,
      set_id text NOT NULL,
      finished_at timestamp NOT NULL,
      PRIMARY KEY (attempt_id, grid)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_checks (
      attempt_id uuid NOT NULL,
      grid text NOT NULL,
      criterion_id text NOT NULL,
      harness_id text NOT NULL,
      wallet_id text NOT NULL,
      run integer NOT NULL,
      criterion text NOT NULL,
      result text,
      reason text,
      PRIMARY KEY (attempt_id, grid, criterion_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_notes (
      key text PRIMARY KEY,
      text text NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_roster (
      kind text NOT NULL,
      id text NOT NULL,
      name text NOT NULL,
      version text,
      website text,
      PRIMARY KEY (kind, id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_fixed (
      harness_id text NOT NULL,
      wallet_id text NOT NULL,
      grid text NOT NULL,
      fixed_outcome text NOT NULL,
      fixed_reason text NOT NULL,
      PRIMARY KEY (harness_id, wallet_id, grid)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_pair_summary (
      set_id text PRIMARY KEY,
      harness_id text NOT NULL,
      wallet_id text NOT NULL,
      grid text NOT NULL,
      current boolean NOT NULL,
      runs integer NOT NULL,
      successes integer NOT NULL,
      caveat_runs integer NOT NULL,
      proof_kind text NOT NULL,
      cost_per_success_usd numeric,
      seconds_per_success numeric,
      last_run_at timestamp NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_extra_notes (
      kind text NOT NULL,
      id text NOT NULL,
      version text NOT NULL,
      note text NOT NULL,
      run_url text,
      noted_at timestamp NOT NULL
    )
    """
  ]

  @doc "Makes Techtree's schema and the bench's tables in `repo`'s database, if missing."
  @spec create!(module()) :: :ok
  def create!(repo) do
    repo.query!("CREATE SCHEMA IF NOT EXISTS techtree_app")
    Enum.each(@tables, &repo.query!/1)
  end
end
