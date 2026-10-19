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

# The shared payment records live in their own schema, which Regents migrates
# in production. The test database gets the same tables here.
RegentPayments.Migrator.up(Patchbay.Repo)

# The same for the shared agent pairing, which the Credits ledger refers to,
# and the shared Credits ledger.
RegentAgents.Migrator.up(Patchbay.Repo)
RegentCredits.Migrator.up(Patchbay.Repo)

# The shared Points tables, which refer to the shared account table the `test`
# alias creates before migrating.
RegentPoints.Migrator.up(Patchbay.Repo)

# config/runtime.exs takes Jev's key from the environment too. Tests ask the
# stand-in in `Patchbay.JevStandIn`, which no key reaches.
Application.put_env(
  :patchbay,
  :openrouter,
  Keyword.put(Application.fetch_env!(:patchbay, :openrouter), :api_key, "test-key-never-sent")
)

Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)
