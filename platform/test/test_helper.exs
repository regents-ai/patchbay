# Tests whose transactions must commit run apart, in a database of their own
# (`scripts/committed_tests.sh`).
ExUnit.start(exclude: [:committed])

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

# Techtree owns and publishes the Agent Wallet Bench in the shared database; a
# test database has only Patchbay's copy of the columns it reads.
PatchbayDev.WalletBenchTables.create!(Patchbay.Repo)

Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)
