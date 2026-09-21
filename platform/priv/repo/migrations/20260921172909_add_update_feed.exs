defmodule Patchbay.Repo.Migrations.AddUpdateFeed do
  @moduledoc """
  Board events become a numbered stream (`seq`) that names what each event
  is about (`resource_id`). Events already on record are numbered in the
  order they happened and pointed at the thread or reply they announced.
  """

  use Ecto.Migration

  def up do
    # The release runs migrations in the app's own schema; a plain database
    # has no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    alter table(:forum_events) do
      add :seq, :bigserial, null: false
      add :resource_id, :uuid
    end

    # Existing rows were numbered in storage order; renumber them by the
    # time they happened, and move the counter past them.
    execute("""
    UPDATE #{schema}.forum_events AS event
    SET seq = numbered.position
    FROM (
      SELECT id, row_number() OVER (ORDER BY inserted_at, id) AS position
      FROM #{schema}.forum_events
    ) AS numbered
    WHERE event.id = numbered.id
    """)

    execute("""
    SELECT setval(
      pg_get_serial_sequence('#{schema}.forum_events', 'seq'),
      GREATEST((SELECT max(seq) FROM #{schema}.forum_events), 1)
    )
    """)

    # A posted thread is about itself; a posted reply is about the reply
    # written just before it in the same transaction; a marked solution is
    # about the reply the thread names.
    execute("""
    UPDATE #{schema}.forum_events
    SET resource_id = thread_id
    WHERE kind = 'thread_posted'
    """)

    execute("""
    UPDATE #{schema}.forum_events AS event
    SET resource_id = (
      SELECT reply.id
      FROM #{schema}.forum_replies AS reply
      WHERE reply.report_id = event.thread_id AND reply.inserted_at <= event.inserted_at
      ORDER BY reply.inserted_at DESC
      LIMIT 1
    )
    WHERE kind = 'reply_posted'
    """)

    execute("""
    UPDATE #{schema}.forum_events AS event
    SET resource_id = report.solution_reply_id
    FROM #{schema}.forum_reports AS report
    WHERE event.kind = 'solution_marked' AND report.id = event.thread_id
    """)

    # An event whose subject cannot be found has nothing to announce.
    execute("DELETE FROM #{schema}.forum_events WHERE resource_id IS NULL")

    alter table(:forum_events) do
      modify :resource_id, :uuid, null: false
    end

    create unique_index(:forum_events, [:seq], name: "forum_events_seq_index")
  end

  def down do
    drop_if_exists unique_index(:forum_events, [:seq], name: "forum_events_seq_index")

    alter table(:forum_events) do
      remove :resource_id
      remove :seq
    end
  end
end
