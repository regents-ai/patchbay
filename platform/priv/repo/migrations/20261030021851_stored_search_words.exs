defmodule Patchbay.Repo.Migrations.StoredSearchWords do
  @moduledoc """
  The words a search finds a thread, a reply, a solution card and a site by,
  kept by the database in a column of each (`search_vector`), so a search reads
  an index (the next migration) instead of every row. Four new columns, filled
  by PostgreSQL itself from each row's own words whenever it is written.

  The columns were generated with `mix ash_postgres.generate_migrations`; their
  expressions are written by hand. Each holds the same words the search read
  before: a thread's title, question, note and tool names (at most five,
  `Patchbay.Forum.Changes.NormalizeToolNames`); a reply's words and every word
  of its fix (`Patchbay.Forum.Fix`), the text of its updates included; a card's
  summary, steps and caveats; a site's address and name. A site's words are
  matched on their own, not copied into its threads.

  A generated column may only use functions that always give the same answer,
  so the tool names are read one by one rather than joined, and the fix's lists
  are read with `jsonb_to_tsvector`. `down` drops the columns.
  """

  use Ecto.Migration

  @report_words """
  ALWAYS AS (to_tsvector('english'::regconfig,
    coalesce(title, '') || ' ' || coalesce(body_markdown, '') || ' ' || coalesce(note, '') || ' ' ||
    coalesce(tool_names[1], '') || ' ' || coalesce(tool_names[2], '') || ' ' ||
    coalesce(tool_names[3], '') || ' ' || coalesce(tool_names[4], '') || ' ' ||
    coalesce(tool_names[5], ''))) STORED
  """

  @reply_words """
  ALWAYS AS (to_tsvector('english'::regconfig,
    coalesce(body_markdown, '') || ' ' || coalesce(note, '') || ' ' ||
    coalesce(fix->>'software', '') || ' ' || coalesce(fix->>'affected_versions', '') || ' ' ||
    coalesce(fix->>'change', '') || ' ' || coalesce(fix->>'test', '') || ' ' ||
    coalesce(fix->>'result', '') || ' ' || coalesce(fix->>'not_covered', ''))
    || coalesce(jsonb_to_tsvector('english'::regconfig, fix->'versions', '["string"]'), ''::tsvector)
    || coalesce(jsonb_to_tsvector('english'::regconfig, fix->'sources', '["string"]'), ''::tsvector)
    || coalesce(jsonb_to_tsvector('english'::regconfig,
         jsonb_path_query_array(fix, '$.updates[*].text'), '["string"]'), ''::tsvector)) STORED
  """

  @card_words """
  ALWAYS AS (to_tsvector('english'::regconfig,
    coalesce(problem_summary, '') || ' ' || coalesce(proposed_steps, '') || ' ' ||
    coalesce(caveats, ''))) STORED
  """

  @site_words """
  ALWAYS AS (to_tsvector('english'::regconfig,
    coalesce(origin, '') || ' ' || coalesce(display_name, ''))) STORED
  """

  # Adding a stored column rewrites its table while every read of it waits, so
  # it gives up after two seconds rather than hold the shared database's other
  # sites; run migrate again.
  def up do
    execute "SET LOCAL lock_timeout = '2s'"

    alter table(:forum_replies) do
      add :search_vector, :tsvector, generated: @reply_words
    end

    alter table(:forum_reports) do
      add :search_vector, :tsvector, generated: @report_words
    end

    alter table(:forum_solution_cards) do
      add :search_vector, :tsvector, generated: @card_words
    end

    alter table(:forum_sites) do
      add :search_vector, :tsvector, generated: @site_words
    end
  end

  def down do
    execute "SET LOCAL lock_timeout = '2s'"

    alter table(:forum_sites) do
      remove :search_vector
    end

    alter table(:forum_solution_cards) do
      remove :search_vector
    end

    alter table(:forum_reports) do
      remove :search_vector
    end

    alter table(:forum_replies) do
      remove :search_vector
    end
  end
end
