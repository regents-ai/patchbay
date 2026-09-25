defmodule Patchbay.Repo.Migrations.RecordWhetherAssistCallsWereMade do
  @moduledoc """
  Every step of an assist that names a tool now says whether the call was
  `made` or only `suggested`. Steps written before carry no `call`; this
  writes it into them. A suggested step's note always began "Suggested";
  every other tool step was a call Patchbay made.
  """

  use Ecto.Migration

  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    execute("""
    UPDATE #{schema}.assist_runs
    SET steps = ARRAY(
      SELECT CASE
        WHEN step ? 'tool' AND NOT step ? 'call' THEN
          step || jsonb_build_object(
            'call',
            CASE WHEN coalesce(step->>'note', '') LIKE 'Suggested%' THEN 'suggested' ELSE 'made' END
          )
        ELSE step
      END
      FROM unnest(steps) WITH ORDINALITY AS kept(step, position)
      ORDER BY position
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(steps) AS old(step) WHERE step ? 'tool' AND NOT step ? 'call'
    )
    """)
  end

  def down do
    raise "irreversible: steps written since also carry `call`"
  end
end
