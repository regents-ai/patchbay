defmodule Patchbay.Repo.Migrations.OfferWordsTurnDownsDeletes do
  @moduledoc """
  Offers are no longer reviewed by hand, can be deleted, and every
  turn-down is logged.

    * Each distinct wording gets one row in `offer_texts`, where a block now
      lives; existing blocks move there from the wordings.
    * Deleting a saved Offer deletes its wordings and their reviews; admin
      decisions and turn-downs that named a wording keep their row.
    * The day's save count gets its own table, filled from saves so far.
    * A review still waiting for a person is turned down, and the admin
      decisions that settled such reviews by hand go with the by-hand step.
  """

  use Ecto.Migration

  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the rows in "public".
    schema = prefix() || "public"

    create table(:offer_texts, primary_key: false) do
      add :text_sha256, :text, null: false, primary_key: true
      add :blocked_at, :utc_datetime_usec
      add :block_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    execute("""
    INSERT INTO #{schema}.offer_texts (text_sha256, blocked_at, block_reason)
    SELECT text_sha256,
           min(blocked_at),
           (array_agg(block_reason ORDER BY blocked_at) FILTER (WHERE blocked_at IS NOT NULL))[1]
    FROM #{schema}.offer_creative_versions
    GROUP BY text_sha256
    """)

    drop constraint(:offer_creative_versions, "offer_creative_versions_creative_id_fkey")

    alter table(:offer_creative_versions) do
      modify :creative_id,
             references(:offer_creatives,
               column: :id,
               name: "offer_creative_versions_creative_id_fkey",
               type: :uuid,
               on_delete: :delete_all
             )

      modify :text_sha256,
             references(:offer_texts,
               column: :text_sha256,
               name: "offer_creative_versions_text_sha256_fkey",
               type: :text,
               on_delete: :restrict
             )

      remove :blocked_at
      remove :block_reason
    end

    drop_if_exists index(:offer_creative_versions, [:blocked_at])

    create table(:offer_turn_downs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :kind, :text, null: false
      add :text, :text, null: false
      add :label, :text, null: false
      add :reason_codes, {:array, :text}, null: false, default: []
      add :private_reason, :text
      add :model, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :owner_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "offer_turn_downs_owner_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :version_id,
          references(:offer_creative_versions,
            column: :id,
            name: "offer_turn_downs_version_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :market_id,
          references(:offer_markets,
            column: :id,
            name: "offer_turn_downs_market_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create index(:offer_turn_downs, [:inserted_at])

    create index(:offer_turn_downs, [:version_id])

    create table(:offer_daily_saves, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :day, :date, null: false
      add :saves, :bigint, null: false

      add :owner_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "offer_daily_saves_owner_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_daily_saves, [:owner_profile_id, :day],
             name: "offer_daily_saves_unique_day_index"
           )

    execute("""
    INSERT INTO #{schema}.offer_daily_saves (owner_profile_id, day, saves)
    SELECT c.owner_profile_id, v.inserted_at::date, count(*)
    FROM #{schema}.offer_creative_versions v
    JOIN #{schema}.offer_creatives c ON c.id = v.creative_id
    GROUP BY 1, 2
    """)

    execute(
      "UPDATE #{schema}.offer_reviews SET decision = 'deny', fresh_until = NULL WHERE decision = 'needs_review'"
    )

    execute(
      "DELETE FROM #{schema}.offer_moderation_actions WHERE kind IN ('allow_version', 'refuse_version')"
    )

    drop constraint(:offer_reviews, "offer_reviews_version_id_fkey")

    alter table(:offer_reviews) do
      modify :version_id,
             references(:offer_creative_versions,
               column: :id,
               name: "offer_reviews_version_id_fkey",
               type: :uuid,
               on_delete: :delete_all
             )

      remove :decided_by_profile_id
    end

    drop constraint(:offer_moderation_actions, "offer_moderation_actions_version_id_fkey")

    alter table(:offer_moderation_actions) do
      modify :version_id,
             references(:offer_creative_versions,
               column: :id,
               name: "offer_moderation_actions_version_id_fkey",
               type: :uuid,
               on_delete: :nilify_all
             )

      remove :review_id
    end

    drop_if_exists index(:offer_moderation_actions, [:review_id])
  end

  def down do
    schema = prefix() || "public"

    drop constraint(:offer_moderation_actions, "offer_moderation_actions_version_id_fkey")

    alter table(:offer_moderation_actions) do
      add :review_id,
          references(:offer_reviews,
            column: :id,
            name: "offer_moderation_actions_review_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )

      modify :version_id,
             references(:offer_creative_versions,
               column: :id,
               name: "offer_moderation_actions_version_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    create index(:offer_moderation_actions, [:review_id])

    drop constraint(:offer_reviews, "offer_reviews_version_id_fkey")

    alter table(:offer_reviews) do
      add :decided_by_profile_id, :uuid

      modify :version_id,
             references(:offer_creative_versions,
               column: :id,
               name: "offer_reviews_version_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    drop constraint(:offer_daily_saves, "offer_daily_saves_owner_profile_id_fkey")

    drop_if_exists unique_index(:offer_daily_saves, [:owner_profile_id, :day],
                     name: "offer_daily_saves_unique_day_index"
                   )

    drop table(:offer_daily_saves)

    drop_if_exists index(:offer_turn_downs, [:version_id])

    drop_if_exists index(:offer_turn_downs, [:inserted_at])

    drop constraint(:offer_turn_downs, "offer_turn_downs_market_id_fkey")

    drop constraint(:offer_turn_downs, "offer_turn_downs_version_id_fkey")

    drop constraint(:offer_turn_downs, "offer_turn_downs_owner_profile_id_fkey")

    drop table(:offer_turn_downs)

    drop constraint(:offer_creative_versions, "offer_creative_versions_text_sha256_fkey")

    drop constraint(:offer_creative_versions, "offer_creative_versions_creative_id_fkey")

    alter table(:offer_creative_versions) do
      add :block_reason, :text
      add :blocked_at, :utc_datetime_usec
      modify :text_sha256, :text

      modify :creative_id,
             references(:offer_creatives,
               column: :id,
               name: "offer_creative_versions_creative_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    create index(:offer_creative_versions, [:blocked_at])

    execute("""
    UPDATE #{schema}.offer_creative_versions v
    SET blocked_at = t.blocked_at, block_reason = t.block_reason
    FROM #{schema}.offer_texts t
    WHERE t.text_sha256 = v.text_sha256 AND t.blocked_at IS NOT NULL
    """)

    drop table(:offer_texts)
  end
end
