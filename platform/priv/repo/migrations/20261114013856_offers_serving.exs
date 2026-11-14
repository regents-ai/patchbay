defmodule Patchbay.Repo.Migrations.OffersServing do
  @moduledoc """
  Serving agent offers (`Patchbay.Offers`): five new tables, empty when made.
  Patchbay's review of each campaign, its pools of advertisers and their
  members, the pools each placement shows from, and each offer delivered.

  Campaigns gain their targeting: four list columns that default to empty and
  a daily limit that defaults to none, so every existing campaign keeps
  exactly what it sealed and its id. The new columns take the campaigns
  table's lock only for a moment; no existing row is rewritten.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:agent_offer_pools, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :tags, {:array, :text}, null: false, default: []

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_pools, [:name], name: "agent_offer_pools_unique_name_index")

    alter table(:agent_offer_campaigns) do
      add :tags, {:array, :text}, null: false, default: []
      add :kinds, {:array, :text}, null: false, default: []
      add :requires, {:array, :text}, null: false, default: []
      add :excluded_wallets, {:array, :text}, null: false, default: []
      add :daily_limit, :bigint
    end

    create table(:agent_offer_pool_members, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :wallet, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :pool_id,
          references(:agent_offer_pools,
            column: :id,
            name: "agent_offer_pool_members_pool_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:agent_offer_pool_members, [:pool_id, :wallet],
             name: "agent_offer_pool_members_unique_member_index"
           )

    create table(:agent_offer_reviews, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :campaign_id, :text, null: false
      add :decision, :text, null: false
      add :reason, :text, null: false, default: ""
      add :moderator_id, :uuid, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:agent_offer_reviews, [:campaign_id, :decision],
             name: "agent_offer_reviews_once_each_index"
           )

    create table(:agent_offer_placement_pools, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :market, :text, null: false
      add :placement_id, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :pool_id,
          references(:agent_offer_pools,
            column: :id,
            name: "agent_offer_placement_pools_pool_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(
             :agent_offer_placement_pools,
             [:chain_id, :market, :placement_id, :pool_id],
             name: "agent_offer_placement_pools_unique_choice_index"
           )

    create table(:agent_offer_deliveries, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :campaign_id, :text, null: false
      add :surface, :text, null: false
      add :viewer_kind, :text, null: false
      add :viewer, :text, null: false
      add :context, :text, null: false
      add :delivered_on, :date, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :lease_id,
          references(:agent_offer_leases,
            column: :id,
            name: "agent_offer_deliveries_lease_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(
             :agent_offer_deliveries,
             [:lease_id, :viewer_kind, :viewer, :context, :delivered_on],
             name: "agent_offer_deliveries_once_a_day_index"
           )
  end

  def down do
    drop constraint(:agent_offer_deliveries, "agent_offer_deliveries_lease_id_fkey")

    drop_if_exists unique_index(
                     :agent_offer_deliveries,
                     [:lease_id, :viewer_kind, :viewer, :context, :delivered_on],
                     name: "agent_offer_deliveries_once_a_day_index"
                   )

    drop table(:agent_offer_deliveries)

    drop constraint(:agent_offer_placement_pools, "agent_offer_placement_pools_pool_id_fkey")

    drop_if_exists unique_index(
                     :agent_offer_placement_pools,
                     [:chain_id, :market, :placement_id, :pool_id],
                     name: "agent_offer_placement_pools_unique_choice_index"
                   )

    drop table(:agent_offer_placement_pools)

    drop_if_exists unique_index(:agent_offer_reviews, [:campaign_id, :decision],
                     name: "agent_offer_reviews_once_each_index"
                   )

    drop table(:agent_offer_reviews)

    drop constraint(:agent_offer_pool_members, "agent_offer_pool_members_pool_id_fkey")

    drop_if_exists unique_index(:agent_offer_pool_members, [:pool_id, :wallet],
                     name: "agent_offer_pool_members_unique_member_index"
                   )

    drop table(:agent_offer_pool_members)

    alter table(:agent_offer_campaigns) do
      remove :daily_limit
      remove :excluded_wallets
      remove :requires
      remove :kinds
      remove :tags
    end

    drop_if_exists unique_index(:agent_offer_pools, [:name],
                     name: "agent_offer_pools_unique_name_index"
                   )

    drop table(:agent_offer_pools)
  end
end
