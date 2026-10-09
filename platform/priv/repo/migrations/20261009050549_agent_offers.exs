defmodule Patchbay.Repo.Migrations.AgentOffers do
  @moduledoc """
  Agent Offers: markets, slots, bids and their windows, placements, creatives,
  reviews, deliveries, reports and moderation, and the global market with its
  three slots. Every table and link is made in the schema the migration runs in.
  """

  use Ecto.Migration

  def up do
    # A release runs migrations in the app's own schema; a plain database has
    # no prefix and keeps the tables in "public".
    schema = prefix() || "public"

    create table(:offer_placements, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :amount_minor, :bigint, null: false
      add :minimum_minor, :bigint, null: false
      add :policy_revision, :bigint, null: false
      add :duration_us, :bigint, null: false
      add :generation, :bigint, null: false
      add :starts_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :status, :text, null: false, default: "active"
      add :returned_minor, :bigint
      add :consumed_minor, :bigint
      add :forfeited_minor, :bigint

      add :owner_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "offer_placements_owner_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :version_id, :uuid, null: false
      add :slot_id, :uuid, null: false
      add :bid_id, :uuid, null: false
    end

    create unique_index(:offer_placements, [:bid_id], name: "offer_placements_unique_bid_index")

    create index(:offer_placements, [:owner_profile_id, :status, :starts_at])

    create index(:offer_placements, [:slot_id, :starts_at])

    create index(:offer_placements, [:id, :slot_id],
             name: "offer_placements_id_slot",
             unique: true
           )

    create table(:offer_creatives, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :label, :text, null: false
      add :archived_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :owner_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "offer_creatives_owner_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create index(:offer_creatives, [:owner_profile_id, :inserted_at])

    create table(:offer_bids, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:offer_placements) do
      modify :bid_id,
             references(:offer_bids,
               column: :id,
               name: "offer_placements_bid_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    alter table(:offer_bids) do
      add :lane, :text, null: false
      add :amount_minor, :bigint, null: false
      add :minimum_minor, :bigint, null: false
      add :opening_minimum_minor, :bigint, null: false
      add :policy_revision, :bigint, null: false
      add :duration_us, :bigint, null: false
      add :target_generation, :bigint, null: false
      add :target_next_revision, :bigint, null: false
      add :sequence, :bigserial, null: false
      add :idempotency_key, :text, null: false
      add :request_sha256, :text, null: false
      add :status, :text, null: false, default: "held"
      add :return_reason, :text
      add :accepted_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :owner_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "offer_bids_owner_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_bids, [:owner_profile_id, :idempotency_key],
             name: "offer_bids_unique_request_index"
           )

    alter table(:offer_bids) do
      add :version_id, :uuid, null: false
      add :slot_id, :uuid, null: false
      add :window_id, :uuid, null: false

      add :target_placement_id,
          references(:offer_placements,
            column: :id,
            name: "offer_bids_target_placement_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create index(:offer_bids, [:owner_profile_id, :inserted_at])

    create index(:offer_bids, [:window_id, :amount_minor, :sequence])

    create index(:offer_bids, [:id, :slot_id], name: "offer_bids_id_slot", unique: true)

    create table(:offer_creative_versions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:offer_placements) do
      modify :version_id,
             references(:offer_creative_versions,
               column: :id,
               name: "offer_placements_version_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    alter table(:offer_bids) do
      modify :version_id,
             references(:offer_creative_versions,
               column: :id,
               name: "offer_bids_version_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    alter table(:offer_creative_versions) do
      add :version, :bigint, null: false
      add :text, :text, null: false
      add :text_sha256, :text, null: false
      add :code_points, :bigint, null: false
      add :byte_count, :bigint, null: false
      add :urls, {:array, :text}, null: false, default: []
      add :bare_addresses, {:array, :text}, null: false, default: []
      add :blocked_at, :utc_datetime_usec
      add :block_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :creative_id,
          references(:offer_creatives,
            column: :id,
            name: "offer_creative_versions_creative_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_creative_versions, [:creative_id, :version],
             name: "offer_creative_versions_unique_version_index"
           )

    create constraint(:offer_creative_versions, :offer_creative_versions_text_limits,
             check: """
               char_length(text) BETWEEN 1 AND 160 AND octet_length(text) <= 640 AND btrim(text) <> '' AND text IS NFC NORMALIZED
             """
           )

    create index(:offer_creative_versions, [:text_sha256])

    create index(:offer_creative_versions, [:blocked_at])

    create table(:offer_bid_windows, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :lane, :text, null: false
      add :target_generation, :bigint, null: false
      add :target_next_revision, :bigint, null: false
      add :baseline_minor, :bigint
      add :opened_at, :utc_datetime_usec, null: false
      add :closes_at, :utc_datetime_usec, null: false
      add :state, :text, null: false, default: "open"
      add :settled_at, :utc_datetime_usec
      add :slot_id, :uuid, null: false

      add :target_placement_id,
          references(:offer_placements,
            column: :id,
            name: "offer_bid_windows_target_placement_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )

      add :winner_bid_id,
          references(:offer_bids,
            column: :id,
            name: "offer_bid_windows_winner_bid_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create index(:offer_bid_windows, [:id, :slot_id, :lane],
             name: "offer_bid_windows_id_slot_lane",
             unique: true
           )

    create table(:offer_markets, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :scope, :text, null: false
      add :minimum_override_minor, :bigint
      add :policy_revision, :bigint, null: false, default: 1

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :site_id,
          references(:forum_sites,
            column: :id,
            name: "offer_markets_site_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create unique_index(:offer_markets, [:site_id], name: "offer_markets_unique_site_index")

    create constraint(:offer_markets, :offer_markets_scope_shape,
             check: """
               (scope = 'site') = (site_id IS NOT NULL)
             """
           )

    create constraint(:offer_markets, :offer_markets_minimum_positive,
             check: """
               minimum_override_minor IS NULL OR (scope = 'site' AND minimum_override_minor > 0)
             """
           )

    create index(:offer_markets, [:scope],
             name: "offer_markets_one_global",
             unique: true,
             where: "scope = 'global'"
           )

    create table(:offer_slots, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
    end

    alter table(:offer_placements) do
      modify :slot_id,
             references(:offer_slots,
               column: :id,
               name: "offer_placements_slot_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    create unique_index(:offer_placements, [:slot_id],
             name: "offer_placements_one_active_per_slot_index",
             where: "(status = 'active')"
           )

    create constraint(:offer_placements, :offer_placements_amount_positive,
             check: """
               amount_minor > 0
             """
           )

    create constraint(:offer_placements, :offer_placements_full_term,
             check: """
               expires_at = starts_at + (duration_us * interval '1 microsecond')
             """
           )

    create constraint(:offer_placements, :offer_placements_settlement_conserves,
             check: """
               CASE status
               WHEN 'active' THEN ended_at IS NULL AND returned_minor IS NULL AND consumed_minor IS NULL AND forfeited_minor IS NULL
               ELSE ended_at IS NOT NULL
                 AND returned_minor IS NOT NULL AND consumed_minor IS NOT NULL AND forfeited_minor IS NOT NULL
                 AND returned_minor >= 0 AND consumed_minor >= 0 AND forfeited_minor >= 0
                 AND returned_minor + consumed_minor + forfeited_minor = amount_minor
                 AND (status <> 'expired' OR (returned_minor = 0 AND forfeited_minor = 0))
                 AND (status <> 'bought_out' OR forfeited_minor = 0)
                 AND (status <> 'removed_for_policy' OR returned_minor = 0)
             END

             """
           )

    create index(:offer_placements, [:expires_at], where: "status = 'active'")

    alter table(:offer_bids) do
      modify :slot_id,
             references(:offer_slots,
               column: :id,
               name: "offer_bids_slot_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    create unique_index(:offer_bids, [:slot_id],
             name: "offer_bids_one_leader_per_slot_index",
             where: "(status = 'leading')"
           )

    create constraint(:offer_bids, :offer_bids_amount_positive,
             check: """
               amount_minor > 0 AND amount_minor >= minimum_minor
             """
           )

    create constraint(:offer_bids, :offer_bids_return_shape,
             check: """
               (status = 'returned') = (return_reason IS NOT NULL) AND (status <> 'returned' OR resolved_at IS NOT NULL)
             """
           )

    execute("""
    ALTER TABLE #{schema}.offer_bids
      ADD CONSTRAINT offer_bids_window_same_slot_and_lane
      FOREIGN KEY (window_id, slot_id, lane)
      REFERENCES #{schema}.offer_bid_windows (id, slot_id, lane)
      ON DELETE RESTRICT
    """)

    alter table(:offer_bid_windows) do
      modify :slot_id,
             references(:offer_slots,
               column: :id,
               name: "offer_bid_windows_slot_id_fkey",
               type: :uuid,
               on_delete: :restrict
             )
    end

    create unique_index(:offer_bid_windows, [:slot_id, :lane],
             name: "offer_bid_windows_one_open_per_lane_index",
             where: "(state = 'open')"
           )

    create constraint(:offer_bid_windows, :offer_bid_windows_two_seconds,
             check: """
               closes_at = opened_at + interval '2 seconds'
             """
           )

    create constraint(:offer_bid_windows, :offer_bid_windows_terminal_shape,
             check: """
               (state = 'open') = (settled_at IS NULL) AND (winner_bid_id IS NULL OR state = 'won')
             """
           )

    create index(:offer_bid_windows, [:closes_at], where: "state = 'open'")

    alter table(:offer_slots) do
      add :number, :bigint, null: false
      add :active_generation, :bigint, null: false, default: 0
      add :next_revision, :bigint, null: false, default: 0

      add :market_id,
          references(:offer_markets,
            column: :id,
            name: "offer_slots_market_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_slots, [:market_id, :number],
             name: "offer_slots_unique_number_index"
           )

    alter table(:offer_slots) do
      add :active_placement_id, :uuid
      add :next_bid_id, :uuid
    end

    create constraint(:offer_slots, :offer_slots_number_range,
             check: """
               number BETWEEN 1 AND 3
             """
           )

    execute("""
    ALTER TABLE #{schema}.offer_slots
      ADD CONSTRAINT offer_slots_active_placement_same_slot
      FOREIGN KEY (active_placement_id, id)
      REFERENCES #{schema}.offer_placements (id, slot_id)
      ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE #{schema}.offer_slots
      ADD CONSTRAINT offer_slots_next_bid_same_slot
      FOREIGN KEY (next_bid_id, id)
      REFERENCES #{schema}.offer_bids (id, slot_id)
      ON DELETE RESTRICT
    """)

    create table(:offer_reviews, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :kind, :text, null: false
      add :decision, :text, null: false, default: "pending"
      add :reason_codes, {:array, :text}, null: false, default: []
      add :private_reason, :text
      add :model, :text
      add :policy_version, :text
      add :input_sha256, :text
      add :destinations, {:array, :map}, null: false, default: []
      add :decided_at, :utc_datetime_usec
      add :fresh_until, :utc_datetime_usec
      add :screen_requested_at, :utc_datetime_usec
      add :decided_by_profile_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :version_id,
          references(:offer_creative_versions,
            column: :id,
            name: "offer_reviews_version_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :market_id,
          references(:offer_markets,
            column: :id,
            name: "offer_reviews_market_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create unique_index(:offer_reviews, [:version_id, :market_id],
             name: "offer_reviews_unique_relevance_index",
             where: "(kind = 'relevance')"
           )

    create unique_index(:offer_reviews, [:version_id],
             name: "offer_reviews_unique_safety_index",
             where: "(kind = 'safety')"
           )

    create constraint(:offer_reviews, :offer_reviews_kind_shape,
             check: """
               (kind = 'relevance') = (market_id IS NOT NULL)
             """
           )

    create index(:offer_reviews, [:screen_requested_at], where: "screen_requested_at IS NOT NULL")

    create index(:offer_reviews, [:fresh_until])

    create table(:offer_deliveries, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :surface, :text, null: false
      add :operation, :text, null: false
      add :selected_at, :utc_datetime_usec, null: false
      add :global_opportunities, {:array, :bigint}, null: false, default: []

      add :site_id,
          references(:forum_sites,
            column: :id,
            name: "offer_deliveries_site_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :report_id,
          references(:forum_reports,
            column: :id,
            name: "offer_deliveries_report_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :reply_id,
          references(:forum_replies,
            column: :id,
            name: "offer_deliveries_reply_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create unique_index(:offer_deliveries, [:report_id],
             name: "offer_deliveries_one_per_post_index",
             where: "(operation <> 'reply')"
           )

    create unique_index(:offer_deliveries, [:reply_id],
             name: "offer_deliveries_one_per_reply_index",
             where: "(operation = 'reply')"
           )

    create constraint(:offer_deliveries, :offer_deliveries_operation_shape,
             check: """
               (operation = 'reply') = (reply_id IS NOT NULL)
             """
           )

    create index(:offer_deliveries, [:site_id, :selected_at])

    create index(:offer_deliveries, [:selected_at])

    create table(:offer_reports, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :reporter, :text, null: false
      add :surface, :text, null: false
      add :reason, :text, null: false
      add :note, :text
      add :status, :text, null: false, default: "open"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :placement_id,
          references(:offer_placements,
            column: :id,
            name: "offer_reports_placement_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_reports, [:reporter, :placement_id],
             name: "offer_reports_once_per_reporter_index"
           )

    alter table(:offer_reports) do
      add :version_id,
          references(:offer_creative_versions,
            column: :id,
            name: "offer_reports_version_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :delivery_id,
          references(:offer_deliveries,
            column: :id,
            name: "offer_reports_delivery_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create constraint(:offer_reports, :offer_reports_note_size,
             check: """
               char_length(note) <= 2000 AND octet_length(note) <= 8192
             """
           )

    create index(:offer_reports, [:status, :inserted_at])

    create index(:offer_reports, [:placement_id, :inserted_at])

    create index(:offer_reports, [:version_id])

    create table(:offer_moderation_actions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :kind, :text, null: false
      add :reason, :text, null: false
      add :idempotency_key, :text, null: false
      add :expected_generation, :bigint
      add :outcome, :text
      add :consumed_minor, :bigint
      add :forfeited_minor, :bigint
      add :policy_revision, :bigint

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :moderator_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "offer_moderation_actions_moderator_profile_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_moderation_actions, [:moderator_profile_id, :idempotency_key],
             name: "offer_moderation_actions_unique_request_index"
           )

    alter table(:offer_moderation_actions) do
      add :placement_id,
          references(:offer_placements,
            column: :id,
            name: "offer_moderation_actions_placement_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )

      add :version_id,
          references(:offer_creative_versions,
            column: :id,
            name: "offer_moderation_actions_version_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )

      add :promoted_placement_id,
          references(:offer_placements,
            column: :id,
            name: "offer_moderation_actions_promoted_placement_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )

      add :report_id,
          references(:offer_reports,
            column: :id,
            name: "offer_moderation_actions_report_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )

      add :review_id,
          references(:offer_reviews,
            column: :id,
            name: "offer_moderation_actions_review_id_fkey",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create index(:offer_moderation_actions, [:inserted_at])

    create index(:offer_moderation_actions, [:placement_id])

    create index(:offer_moderation_actions, [:version_id])

    create index(:offer_moderation_actions, [:report_id])

    create index(:offer_moderation_actions, [:review_id])

    create table(:offer_delivery_items, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :position, :bigint, null: false
      add :scope, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :delivery_id,
          references(:offer_deliveries,
            column: :id,
            name: "offer_delivery_items_delivery_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:offer_delivery_items, [:delivery_id, :position],
             name: "offer_delivery_items_one_per_position_index"
           )

    alter table(:offer_delivery_items) do
      add :placement_id,
          references(:offer_placements,
            column: :id,
            name: "offer_delivery_items_placement_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :version_id,
          references(:offer_creative_versions,
            column: :id,
            name: "offer_delivery_items_version_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create constraint(:offer_delivery_items, :offer_delivery_items_position_range,
             check: """
               position BETWEEN 1 AND 3
             """
           )

    create index(:offer_delivery_items, [:placement_id, :inserted_at])

    execute("""
    INSERT INTO #{schema}.offer_markets (id, scope, policy_revision, inserted_at)
    VALUES (gen_random_uuid(), 'global', 1, (now() AT TIME ZONE 'utc'))
    """)

    execute("""
    INSERT INTO #{schema}.offer_slots (id, market_id, number, active_generation, next_revision)
    SELECT gen_random_uuid(), market.id, slot.number, 0, 0
    FROM #{schema}.offer_markets market, generate_series(1, 3) AS slot(number)
    WHERE market.scope = 'global'
    """)
  end

  def down do
    schema = prefix() || "public"

    drop_if_exists index(:offer_delivery_items, [:placement_id, :inserted_at])

    drop_if_exists constraint(:offer_delivery_items, :offer_delivery_items_position_range)

    drop constraint(:offer_delivery_items, "offer_delivery_items_version_id_fkey")

    drop constraint(:offer_delivery_items, "offer_delivery_items_placement_id_fkey")

    drop constraint(:offer_delivery_items, "offer_delivery_items_delivery_id_fkey")

    alter table(:offer_delivery_items) do
      remove :version_id
      remove :placement_id
    end

    drop_if_exists unique_index(:offer_delivery_items, [:delivery_id, :position],
                     name: "offer_delivery_items_one_per_position_index"
                   )

    drop table(:offer_delivery_items)

    drop_if_exists index(:offer_moderation_actions, [:review_id])

    drop_if_exists index(:offer_moderation_actions, [:report_id])

    drop_if_exists index(:offer_moderation_actions, [:version_id])

    drop_if_exists index(:offer_moderation_actions, [:placement_id])

    drop_if_exists index(:offer_moderation_actions, [:inserted_at])

    drop constraint(:offer_moderation_actions, "offer_moderation_actions_review_id_fkey")

    drop constraint(:offer_moderation_actions, "offer_moderation_actions_report_id_fkey")

    drop constraint(
           :offer_moderation_actions,
           "offer_moderation_actions_promoted_placement_id_fkey"
         )

    drop constraint(:offer_moderation_actions, "offer_moderation_actions_version_id_fkey")

    drop constraint(:offer_moderation_actions, "offer_moderation_actions_placement_id_fkey")

    drop constraint(
           :offer_moderation_actions,
           "offer_moderation_actions_moderator_profile_id_fkey"
         )

    alter table(:offer_moderation_actions) do
      remove :review_id
      remove :report_id
      remove :promoted_placement_id
      remove :version_id
      remove :placement_id
    end

    drop_if_exists unique_index(
                     :offer_moderation_actions,
                     [:moderator_profile_id, :idempotency_key],
                     name: "offer_moderation_actions_unique_request_index"
                   )

    drop table(:offer_moderation_actions)

    drop_if_exists index(:offer_reports, [:version_id])

    drop_if_exists index(:offer_reports, [:placement_id, :inserted_at])

    drop_if_exists index(:offer_reports, [:status, :inserted_at])

    drop_if_exists constraint(:offer_reports, :offer_reports_note_size)

    drop constraint(:offer_reports, "offer_reports_delivery_id_fkey")

    drop constraint(:offer_reports, "offer_reports_version_id_fkey")

    drop constraint(:offer_reports, "offer_reports_placement_id_fkey")

    alter table(:offer_reports) do
      remove :delivery_id
      remove :version_id
    end

    drop_if_exists unique_index(:offer_reports, [:reporter, :placement_id],
                     name: "offer_reports_once_per_reporter_index"
                   )

    drop table(:offer_reports)

    drop_if_exists index(:offer_deliveries, [:selected_at])

    drop_if_exists index(:offer_deliveries, [:site_id, :selected_at])

    drop_if_exists constraint(:offer_deliveries, :offer_deliveries_operation_shape)

    drop constraint(:offer_deliveries, "offer_deliveries_reply_id_fkey")

    drop constraint(:offer_deliveries, "offer_deliveries_report_id_fkey")

    drop constraint(:offer_deliveries, "offer_deliveries_site_id_fkey")

    drop_if_exists unique_index(:offer_deliveries, [:reply_id],
                     name: "offer_deliveries_one_per_reply_index"
                   )

    drop_if_exists unique_index(:offer_deliveries, [:report_id],
                     name: "offer_deliveries_one_per_post_index"
                   )

    drop table(:offer_deliveries)

    drop_if_exists index(:offer_reviews, [:fresh_until])

    drop_if_exists index(:offer_reviews, [:screen_requested_at])

    drop_if_exists constraint(:offer_reviews, :offer_reviews_kind_shape)

    drop constraint(:offer_reviews, "offer_reviews_market_id_fkey")

    drop constraint(:offer_reviews, "offer_reviews_version_id_fkey")

    drop_if_exists unique_index(:offer_reviews, [:version_id],
                     name: "offer_reviews_unique_safety_index"
                   )

    drop_if_exists unique_index(:offer_reviews, [:version_id, :market_id],
                     name: "offer_reviews_unique_relevance_index"
                   )

    drop table(:offer_reviews)

    execute("""
    ALTER TABLE #{schema}.offer_slots DROP CONSTRAINT offer_slots_next_bid_same_slot
    """)

    execute("""
    ALTER TABLE #{schema}.offer_slots DROP CONSTRAINT offer_slots_active_placement_same_slot
    """)

    drop_if_exists constraint(:offer_slots, :offer_slots_number_range)

    drop constraint(:offer_slots, "offer_slots_market_id_fkey")

    alter table(:offer_slots) do
      remove :next_bid_id
      remove :active_placement_id
    end

    drop_if_exists unique_index(:offer_slots, [:market_id, :number],
                     name: "offer_slots_unique_number_index"
                   )

    alter table(:offer_slots) do
      remove :market_id
      remove :next_revision
      remove :active_generation
      remove :number
    end

    drop_if_exists index(:offer_bid_windows, [:closes_at])

    drop_if_exists constraint(:offer_bid_windows, :offer_bid_windows_terminal_shape)

    drop_if_exists constraint(:offer_bid_windows, :offer_bid_windows_two_seconds)

    drop constraint(:offer_bid_windows, "offer_bid_windows_winner_bid_id_fkey")

    drop constraint(:offer_bid_windows, "offer_bid_windows_target_placement_id_fkey")

    drop constraint(:offer_bid_windows, "offer_bid_windows_slot_id_fkey")

    drop_if_exists unique_index(:offer_bid_windows, [:slot_id, :lane],
                     name: "offer_bid_windows_one_open_per_lane_index"
                   )

    alter table(:offer_bid_windows) do
      modify :slot_id, :uuid
    end

    execute("""
    ALTER TABLE #{schema}.offer_bids DROP CONSTRAINT offer_bids_window_same_slot_and_lane
    """)

    drop_if_exists constraint(:offer_bids, :offer_bids_return_shape)

    drop_if_exists constraint(:offer_bids, :offer_bids_amount_positive)

    drop constraint(:offer_bids, "offer_bids_target_placement_id_fkey")

    drop constraint(:offer_bids, "offer_bids_slot_id_fkey")

    drop constraint(:offer_bids, "offer_bids_version_id_fkey")

    drop constraint(:offer_bids, "offer_bids_owner_profile_id_fkey")

    drop_if_exists unique_index(:offer_bids, [:slot_id],
                     name: "offer_bids_one_leader_per_slot_index"
                   )

    alter table(:offer_bids) do
      modify :slot_id, :uuid
    end

    drop_if_exists index(:offer_placements, [:expires_at])

    drop_if_exists constraint(:offer_placements, :offer_placements_settlement_conserves)

    drop_if_exists constraint(:offer_placements, :offer_placements_full_term)

    drop_if_exists constraint(:offer_placements, :offer_placements_amount_positive)

    drop constraint(:offer_placements, "offer_placements_bid_id_fkey")

    drop constraint(:offer_placements, "offer_placements_slot_id_fkey")

    drop constraint(:offer_placements, "offer_placements_version_id_fkey")

    drop constraint(:offer_placements, "offer_placements_owner_profile_id_fkey")

    drop_if_exists unique_index(:offer_placements, [:slot_id],
                     name: "offer_placements_one_active_per_slot_index"
                   )

    alter table(:offer_placements) do
      modify :slot_id, :uuid
    end

    drop table(:offer_slots)

    drop_if_exists index(:offer_markets, [:scope], name: "offer_markets_one_global")

    drop_if_exists constraint(:offer_markets, :offer_markets_minimum_positive)

    drop_if_exists constraint(:offer_markets, :offer_markets_scope_shape)

    drop constraint(:offer_markets, "offer_markets_site_id_fkey")

    drop_if_exists unique_index(:offer_markets, [:site_id],
                     name: "offer_markets_unique_site_index"
                   )

    drop table(:offer_markets)

    drop_if_exists index(:offer_bid_windows, [:id, :slot_id, :lane],
                     name: "offer_bid_windows_id_slot_lane"
                   )

    drop table(:offer_bid_windows)

    drop_if_exists index(:offer_creative_versions, [:blocked_at])

    drop_if_exists index(:offer_creative_versions, [:text_sha256])

    drop_if_exists constraint(:offer_creative_versions, :offer_creative_versions_text_limits)

    drop constraint(:offer_creative_versions, "offer_creative_versions_creative_id_fkey")

    drop_if_exists unique_index(:offer_creative_versions, [:creative_id, :version],
                     name: "offer_creative_versions_unique_version_index"
                   )

    alter table(:offer_creative_versions) do
      remove :creative_id
      remove :inserted_at
      remove :block_reason
      remove :blocked_at
      remove :bare_addresses
      remove :urls
      remove :byte_count
      remove :code_points
      remove :text_sha256
      remove :text
      remove :version
    end

    alter table(:offer_bids) do
      modify :version_id, :uuid
    end

    alter table(:offer_placements) do
      modify :version_id, :uuid
    end

    drop table(:offer_creative_versions)

    drop_if_exists index(:offer_bids, [:id, :slot_id], name: "offer_bids_id_slot")

    drop_if_exists index(:offer_bids, [:window_id, :amount_minor, :sequence])

    drop_if_exists index(:offer_bids, [:owner_profile_id, :inserted_at])

    alter table(:offer_bids) do
      remove :target_placement_id
      remove :window_id
      remove :slot_id
      remove :version_id
    end

    drop_if_exists unique_index(:offer_bids, [:owner_profile_id, :idempotency_key],
                     name: "offer_bids_unique_request_index"
                   )

    alter table(:offer_bids) do
      remove :owner_profile_id
      remove :inserted_at
      remove :resolved_at
      remove :accepted_at
      remove :return_reason
      remove :status
      remove :request_sha256
      remove :idempotency_key
      remove :sequence
      remove :target_next_revision
      remove :target_generation
      remove :duration_us
      remove :policy_revision
      remove :opening_minimum_minor
      remove :minimum_minor
      remove :amount_minor
      remove :lane
    end

    alter table(:offer_placements) do
      modify :bid_id, :uuid
    end

    drop table(:offer_bids)

    drop_if_exists index(:offer_creatives, [:owner_profile_id, :inserted_at])

    drop constraint(:offer_creatives, "offer_creatives_owner_profile_id_fkey")

    drop table(:offer_creatives)

    drop_if_exists index(:offer_placements, [:id, :slot_id], name: "offer_placements_id_slot")

    drop_if_exists index(:offer_placements, [:slot_id, :starts_at])

    drop_if_exists index(:offer_placements, [:owner_profile_id, :status, :starts_at])

    drop_if_exists unique_index(:offer_placements, [:bid_id],
                     name: "offer_placements_unique_bid_index"
                   )

    drop table(:offer_placements)
  end
end
