defmodule Mix.Tasks.Patchbay.SetupLocalAuth do
  use Mix.Task

  @shortdoc "Prepares the guarded local Patchbay database"

  # Only the database connection runs, so a database without the job tables yet
  # can still be brought up to date.
  @impl true
  def run(_args) do
    unless Mix.env() == :dev, do: Mix.raise("local database setup is dev only")
    Mix.Task.run("app.config")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Patchbay.Repo, fn _repo ->
        Patchbay.LocalDatabaseFixture.ensure_human_accounts!()
      end)

    Mix.shell().info("Local Patchbay database is ready.")
  end
end
