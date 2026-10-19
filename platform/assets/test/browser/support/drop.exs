# The end of a browser walk: drop the database made for this run
# (assets/playwright.config.ts), even while the walk's server is still connected to
# it. PatchbayDev.WalkDatabase refuses any database but a walk's own local one.
repo = PatchbayDev.WalkDatabase.own!(Patchbay.Repo.config())

case Ecto.Adapters.Postgres.storage_down(Keyword.put(repo, :force_drop, true)) do
  :ok -> :ok
  {:error, :already_down} -> :ok
end
