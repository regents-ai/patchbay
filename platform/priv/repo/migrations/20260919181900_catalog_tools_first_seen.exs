defmodule Patchbay.Repo.Migrations.CatalogToolsFirstSeen do
  @moduledoc """
  A documented tool's first-seen date is the date its publication was checked,
  the same date it was last seen. Rows imported before that rule carry the
  date of their own import instead, which is later than the checked date.
  """

  use Ecto.Migration

  def up do
    # The release runs migrations in the app's own schema; a plain database
    # has no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    execute("""
    UPDATE #{schema}.forum_tools
    SET first_seen_at = last_seen_at
    WHERE source_kind = 'official' AND first_seen_at > last_seen_at
    """)
  end

  def down do
    :ok
  end
end
