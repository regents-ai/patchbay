defmodule Patchbay.Repo.Migrations.AddOban do
  @moduledoc "Oban's job tables, in the app's own schema."

  use Ecto.Migration

  # The release runs migrations in the app's own schema; a plain database has
  # no prefix and keeps the tables in "public".
  def up, do: Oban.Migrations.up(prefix: prefix() || "public")

  def down, do: Oban.Migrations.down(prefix: prefix() || "public", version: 1)
end
