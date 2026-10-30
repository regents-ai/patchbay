defmodule Patchbay.Repo.Migrations.ToolNameTrigramIndex do
  @moduledoc """
  A tool's name in three-letter pieces, so the front page's tool match
  (`Patchbay.Forum.Tool`'s `:find`) finds a name containing the typed words,
  or nearly matching them, without reading every tool.

  One of four indexes for the site and tool matches, one per migration,
  smallest table first: every condition of a match reads an index, so none
  reads the whole table. Each is built while reads and writes go on
  (`CONCURRENTLY`), outside a transaction, and adds no column, so no table is
  rewritten. A build that stops part way leaves an unusable index behind and
  this migration unrecorded; running migrate again drops it and builds it
  afresh, and the release stops while any index is unusable
  (`Patchbay.Release.migrate/1`). The index is declared on the resource too,
  so `mix ash.codegen` knows it.
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
    index(:forum_tools, ["name public.gin_trgm_ops"],
      name: "forum_tools_name_trgm_index",
      using: "GIN",
      concurrently: true
    )
  end
end
