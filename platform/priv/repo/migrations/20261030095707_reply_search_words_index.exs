defmodule Patchbay.Repo.Migrations.ReplySearchWordsIndex do
  @moduledoc """
  A reply's words, what it says and every word of its fix: exactly
  `Patchbay.Forum.Reply`'s `search_vector`, so a search reads this instead of
  every reply.

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
      :forum_replies,
      [
        "(to_tsvector('english'::regconfig, coalesce(body_markdown, '') || ' ' || coalesce(note, '') || ' ' || coalesce(fix->>'software', '') || ' ' || coalesce(fix->>'affected_versions', '') || ' ' || coalesce(fix->>'change', '') || ' ' || coalesce(fix->>'test', '') || ' ' || coalesce(fix->>'result', '') || ' ' || coalesce(fix->>'not_covered', '')) || coalesce(jsonb_to_tsvector('english'::regconfig, fix->'versions', '[\"string\"]'), ''::tsvector) || coalesce(jsonb_to_tsvector('english'::regconfig, fix->'sources', '[\"string\"]'), ''::tsvector) || coalesce(jsonb_to_tsvector('english'::regconfig, jsonb_path_query_array(fix, '$.updates[*].text'), '[\"string\"]'), ''::tsvector))"
      ],
      name: "forum_replies_search_words_index",
      using: "GIN",
      concurrently: true
    )
  end
end
