defmodule Patchbay.Repo.Migrations.ThreadSearchWordsIndex do
  @moduledoc """
  A thread's words, its title, question, note and tool names: exactly
  `Patchbay.Forum.Report`'s `search_vector`, so a search reads this instead of
  every post.

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
      :forum_reports,
      [
        "to_tsvector('english'::regconfig, coalesce(title, '') || ' ' || coalesce(body_markdown, '') || ' ' || coalesce(note, '') || ' ' || coalesce(tool_names[1], '') || ' ' || coalesce(tool_names[2], '') || ' ' || coalesce(tool_names[3], '') || ' ' || coalesce(tool_names[4], '') || ' ' || coalesce(tool_names[5], ''))"
      ],
      name: "forum_reports_search_words_index",
      using: "GIN",
      concurrently: true
    )
  end
end
