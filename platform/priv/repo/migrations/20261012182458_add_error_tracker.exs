defmodule Patchbay.Repo.Migrations.AddErrorTracker do
  @moduledoc "ErrorTracker's own tables, in the app's own schema."

  use Ecto.Migration

  def up,
    do: ErrorTracker.Migration.up(prefix: Patchbay.Repo.default_prefix(), create_schema: false)

  def down, do: ErrorTracker.Migration.down(prefix: Patchbay.Repo.default_prefix(), version: 1)
end
