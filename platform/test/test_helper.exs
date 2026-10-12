ExUnit.start()

# The shared payment records live in their own schema, which Regents migrates
# in production. The test database gets the same tables here.
RegentPayments.Migrator.up(Patchbay.Repo)

# The same for the shared agent pairing, which the Credits ledger refers to,
# and the shared Credits ledger.
RegentAgents.Migrator.up(Patchbay.Repo)
RegentCredits.Migrator.up(Patchbay.Repo)

Ecto.Adapters.SQL.Sandbox.mode(Patchbay.Repo, :manual)
