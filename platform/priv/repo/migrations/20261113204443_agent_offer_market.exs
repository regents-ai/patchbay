defmodule Patchbay.Repo.Migrations.AgentOfferMarket do
  @moduledoc """
  Agent offers (`Patchbay.Offers`): seven new tables, empty when made. The
  campaigns advertisers write, Patchbay's accepted and blocked advertiser
  wallets, the market's placements, terminations, leases and settlements as
  the chain gave them, and how far the market has been read. Touches no
  existing row; the campaigns' link to `agent_profiles` takes that table's
  lock only for a moment.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:agent_offer_cursors, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :market, :text, null: false
      add :next_block, :bigint, null: false
      add :head_block, :bigint
      add :head_block_hash, :text
      add :observed_at, :utc_datetime_usec
      add :rescan_from, :bigint

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_cursors, [:chain_id, :market],
             name: "agent_offer_cursors_unique_cursor_index"
           )

    create table(:agent_offer_advertiser_rules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :wallet, :text, null: false
      add :verdict, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_advertiser_rules, [:wallet, :verdict],
             name: "agent_offer_advertiser_rules_unique_rule_index"
           )

    create table(:agent_offer_campaigns, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :campaign_id, :text, null: false
      add :advertiser, :text, null: false
      add :title, :text, null: false
      add :body, :text, null: false
      add :link, :text, null: false
      add :audience, :text, null: false
      add :sites, {:array, :text}, null: false, default: []
      add :group, :text
      add :notes, :text, null: false, default: ""

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :agent_profile_id,
          references(:agent_profiles,
            column: :id,
            name: "agent_offer_campaigns_agent_profile_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:agent_offer_campaigns, [:campaign_id],
             name: "agent_offer_campaigns_unique_campaign_index"
           )

    create table(:agent_offer_settlements, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :market, :text, null: false
      add :transaction_hash, :text, null: false
      add :log_index, :bigint, null: false
      add :block_number, :bigint, null: false
      add :block_hash, :text, null: false
      add :placement_id, :bigint, null: false
      add :slot, :bigint, null: false
      add :buyer, :text, null: false
      add :nonce, :bigint, null: false
      add :reason, :text, null: false
      add :settled_at, :utc_datetime, null: false
      add :refund_usdc, :decimal, null: false
      add :publisher_usdc, :decimal, null: false
      add :fee_usdc, :decimal, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_settlements, [:chain_id, :transaction_hash, :log_index],
             name: "agent_offer_settlements_unique_chain_event_index"
           )

    create table(:agent_offer_terminations, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :market, :text, null: false
      add :transaction_hash, :text, null: false
      add :log_index, :bigint, null: false
      add :block_number, :bigint, null: false
      add :block_hash, :text, null: false
      add :placement_id, :bigint, null: false
      add :terminated_at, :utc_datetime, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_terminations, [:chain_id, :transaction_hash, :log_index],
             name: "agent_offer_terminations_unique_chain_event_index"
           )

    create table(:agent_offer_placements, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :market, :text, null: false
      add :transaction_hash, :text, null: false
      add :log_index, :bigint, null: false
      add :block_number, :bigint, null: false
      add :block_hash, :text, null: false
      add :placement_id, :bigint, null: false
      add :source_id, :text, null: false
      add :capacity, :bigint, null: false
      add :duration_seconds, :bigint, null: false
      add :min_bump_bps, :bigint, null: false
      add :floor_usdc, :decimal, null: false
      add :policy_hash, :text, null: false
      add :metadata_uri, :text, null: false
      add :source_origin, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_placements, [:chain_id, :transaction_hash, :log_index],
             name: "agent_offer_placements_unique_chain_event_index"
           )

    create table(:agent_offer_leases, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :market, :text, null: false
      add :transaction_hash, :text, null: false
      add :log_index, :bigint, null: false
      add :block_number, :bigint, null: false
      add :block_hash, :text, null: false
      add :placement_id, :bigint, null: false
      add :slot, :bigint, null: false
      add :buyer, :text, null: false
      add :campaign_id, :text, null: false
      add :paid_usdc, :decimal, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :nonce, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_leases, [:chain_id, :transaction_hash, :log_index],
             name: "agent_offer_leases_unique_chain_event_index"
           )
  end

  def down do
    drop_if_exists unique_index(:agent_offer_leases, [:chain_id, :transaction_hash, :log_index],
                     name: "agent_offer_leases_unique_chain_event_index"
                   )

    drop table(:agent_offer_leases)

    drop_if_exists unique_index(
                     :agent_offer_placements,
                     [:chain_id, :transaction_hash, :log_index],
                     name: "agent_offer_placements_unique_chain_event_index"
                   )

    drop table(:agent_offer_placements)

    drop_if_exists unique_index(
                     :agent_offer_terminations,
                     [:chain_id, :transaction_hash, :log_index],
                     name: "agent_offer_terminations_unique_chain_event_index"
                   )

    drop table(:agent_offer_terminations)

    drop_if_exists unique_index(
                     :agent_offer_settlements,
                     [:chain_id, :transaction_hash, :log_index],
                     name: "agent_offer_settlements_unique_chain_event_index"
                   )

    drop table(:agent_offer_settlements)

    drop constraint(:agent_offer_campaigns, "agent_offer_campaigns_agent_profile_id_fkey")

    drop_if_exists unique_index(:agent_offer_campaigns, [:campaign_id],
                     name: "agent_offer_campaigns_unique_campaign_index"
                   )

    drop table(:agent_offer_campaigns)

    drop_if_exists unique_index(:agent_offer_advertiser_rules, [:wallet, :verdict],
                     name: "agent_offer_advertiser_rules_unique_rule_index"
                   )

    drop table(:agent_offer_advertiser_rules)

    drop_if_exists unique_index(:agent_offer_cursors, [:chain_id, :market],
                     name: "agent_offer_cursors_unique_cursor_index"
                   )

    drop table(:agent_offer_cursors)
  end
end
