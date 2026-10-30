defmodule Patchbay.Repo.Migrations.SiteSearchWordsIndex do
  @moduledoc """
  A site's words, its address and name: exactly `Patchbay.Forum.Site`'s
  `search_vector`, so a search reads this instead of every site.

  One of seven search indexes, one per migration, smallest table first. Each is
  built while reads and writes go on (`CONCURRENTLY`), outside a transaction,
  and adds no column, so no table is rewritten. A build that stops part way
  leaves an unusable index behind and this migration unrecorded; running
  migrate again drops it and builds it afresh, and the release stops while any
  index is unusable (`Patchbay.Release.migrate/1`). The index is declared on
  the resource too, so `mix ash.codegen` knows it.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    drop_if_exists search_index()
    create search_index()
  end

  def down, do: drop_if_exists(search_index())

  defp search_index do
    index(
      :forum_sites,
      [
        "to_tsvector('english'::regconfig, coalesce(origin, '') || ' ' || coalesce(display_name, ''))"
      ],
      name: "forum_sites_search_words_index",
      using: "GIN",
      concurrently: true
    )
  end
end
