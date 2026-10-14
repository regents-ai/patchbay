ExUnit.start()

# The shared payment records live in their own schema, which Regents migrates
# in production. The test database gets the same tables here.
RegentPayments.Migrator.up(Patchbay.Repo)

# The same for the shared agent pairing, which the Credits ledger refers to,
# and the shared Credits ledger.
RegentAgents.Migrator.up(Patchbay.Repo)
RegentCredits.Migrator.up(Patchbay.Repo)

# The shared Regent account table, which the platform owns and migrates in
# production.
for statement <- Patchbay.SharedAccountTable.statements(),
    do: Ecto.Adapters.SQL.query!(Patchbay.Repo, statement, [])

# The shared Points tables, which refer to that account table.
RegentPoints.Migrator.up(Patchbay.Repo)

# config/runtime.exs names the SIWA service from the environment, which tests
# leave unset; each test's stub answers for it here instead.
Application.put_env(
  :regent_agents,
  :siwa,
  Keyword.put(Application.fetch_env!(:regent_agents, :siwa), :url, "https://siwa.test")
)

# config/runtime.exs takes Jev's key from the environment too. Tests ask the
# stand-in in `Patchbay.JevStandIn`, which no key reaches.
Application.put_env(
  :patchbay,
  :openrouter,
  Keyword.put(Application.fetch_env!(:patchbay, :openrouter), :api_key, "test-key-never-sent")
)

Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)
