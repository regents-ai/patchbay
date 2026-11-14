defmodule Patchbay.Repo.Migrations.FillEventAuthors do
  @moduledoc """
  Fills, once, `forum_events.author_profile_id` (added empty by `EventAuthor`)
  on the events written before it, from what each event's own record already
  says, by the same rule a new event is written with:

  - `thread_posted`: the thread's author (`forum_reports.author_profile_id`).
  - `reply_posted`: the reply's author (`forum_replies.author_profile_id`).
  - `solution_marked`: the agent that named the answer, where the event
    recorded one (`forum_events.acting_agent_id`).

  It writes only that one column, only where it is still empty and the
  source names someone; it deletes nothing and changes no other column. A
  thread or reply nobody signed in wrote stays empty, as a new one would. A
  `solution_marked` event with no agent recorded stays empty too: the answer
  was named by a person on the page, a visitor, Patchbay, or an agent before
  agents were recorded on events, and the event does not say which. The
  counts before and after are printed in the release step.
  """

  use Ecto.Migration

  # It gives up after five seconds rather than hold every new post behind the
  # events table's lock; run migrate again.
  def up do
    schema = prefix() || "public"

    execute("SET LOCAL lock_timeout = '5s'")
    flush()
    IO.puts("event author fill, before: " <> counts(schema))

    execute("""
    UPDATE #{schema}.forum_events AS event
    SET author_profile_id = thread.author_profile_id
    FROM #{schema}.forum_reports AS thread
    WHERE event.kind = 'thread_posted'
      AND event.author_profile_id IS NULL
      AND thread.id = event.resource_id
      AND thread.author_profile_id IS NOT NULL
    """)

    execute("""
    UPDATE #{schema}.forum_events AS event
    SET author_profile_id = reply.author_profile_id
    FROM #{schema}.forum_replies AS reply
    WHERE event.kind = 'reply_posted'
      AND event.author_profile_id IS NULL
      AND reply.id = event.resource_id
      AND reply.author_profile_id IS NOT NULL
    """)

    execute("""
    UPDATE #{schema}.forum_events
    SET author_profile_id = acting_agent_id
    WHERE kind = 'solution_marked'
      AND author_profile_id IS NULL
      AND acting_agent_id IS NOT NULL
    """)

    flush()
    IO.puts("event author fill, after: " <> counts(schema))
  end

  # Nothing to undo here: `EventAuthor`'s `down` drops the column, and what
  # this filled goes with it.
  def down, do: :ok

  defp counts(schema) do
    %{rows: rows} =
      repo().query!("""
      SELECT kind, count(*), count(author_profile_id)
      FROM #{schema}.forum_events
      GROUP BY kind
      ORDER BY kind
      """)

    Enum.map_join(rows, ", ", fn [kind, events, named] ->
      "#{kind} #{events} (author named #{named})"
    end)
  end
end
