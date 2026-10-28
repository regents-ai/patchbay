ExUnit.start()

# No test reaches outside this machine (PatchbayTest.Offline). A refused request
# fails the run even when a background process made it and nothing raised in a test.
PatchbayTest.Offline.start()

ExUnit.after_suite(fn _results ->
  case PatchbayTest.Offline.refused() do
    [] ->
      :ok

    refused ->
      IO.puts(:stderr, "\nTests reached outside this machine:\n" <> Enum.join(refused, "\n"))
      System.halt(1)
  end
end)

# config/runtime.exs takes Jev's key from the environment too. Tests ask the
# stand-in in `Patchbay.JevStandIn`, which no key reaches.
Application.put_env(
  :patchbay,
  :openrouter,
  Keyword.put(Application.fetch_env!(:patchbay, :openrouter), :api_key, "test-key-never-sent")
)

# Techtree owns and publishes the Agent Wallet Bench results in the shared
# database (`Patchbay.WalletBench.Result`); a test database has only this copy
# of the columns Patchbay reads.
Patchbay.Repo.query!("CREATE SCHEMA IF NOT EXISTS techtree_app")

Patchbay.Repo.query!("""
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
""")

Patchbay.Repo.query!("""
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
""")

Patchbay.Repo.query!("""
CREATE TABLE IF NOT EXISTS techtree_app.wallet_bench_notes (
  key text PRIMARY KEY,
  text text NOT NULL
)
""")

Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)
