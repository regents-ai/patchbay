defmodule Patchbay.Repo.Migrations.SampleNamesInStoredRooms do
  @moduledoc """
  The built-in sample answer and plan are named "sample" now. Past rooms
  stored the old names, so their sample box would no longer show: each
  stored result, plan and timeline entry is renamed in place.
  """

  use Ecto.Migration

  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    execute("""
    UPDATE #{schema}.invocations
    SET handler_result = jsonb_set(
      handler_result,
      '{candidate_provenance}',
      ((handler_result->'candidate_provenance') - 'fallback_used' - 'fallback_reason')
        || jsonb_build_object(
             'sample_used', handler_result->'candidate_provenance'->'fallback_used',
             'sample_reason', handler_result->'candidate_provenance'->'fallback_reason'
           )
        || CASE WHEN handler_result->'candidate_provenance'->>'model' = 'patchbay-demo-fallback'
             THEN jsonb_build_object(
                    'model', 'patchbay-sample',
                    'model_response_id',
                    regexp_replace(
                      handler_result->'candidate_provenance'->>'model_response_id',
                      '^demo-fallback-',
                      'sample-'
                    )
                  )
             ELSE '{}'::jsonb
           END
    )
    WHERE (handler_result->'candidate_provenance') ? 'fallback_used'
    """)

    execute("""
    UPDATE #{schema}.repair_proposals
    SET model = 'patchbay-sample',
        model_response_id = CASE model_response_id
          WHEN 'demo-repair-fallback' THEN 'sample-repair'
          ELSE model_response_id
        END
    WHERE model = 'patchbay-demo-fallback'
    """)

    execute("""
    UPDATE #{schema}.room_events
    SET payload = (payload - 'fallback_used')
      || jsonb_build_object('sample_used', payload->'fallback_used')
    WHERE payload ? 'fallback_used'
    """)
  end

  def down do
    raise Ecto.MigrationError, "Stored rooms keep the sample names."
  end
end
