defmodule Patchbay.Offers.Lease do
  @moduledoc """
  One `LeasePurchased` event of Patchbay's market, exactly as the chain gave
  it, never rewritten: a slot bought for one full term, by whom, for which
  campaign and for how much. A slot's lease with the highest nonce whose term
  has not run out is the one it shows, unless its placement was terminated.

  `delivery_count` counts the times Patchbay showed it
  (`Patchbay.Offers.Delivery`): all of them for a moderator, and for an
  advertiser only on their own campaigns' leases.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @address ~r/\A0x[0-9a-f]{40}\z/
  @hash ~r/\A0x[0-9a-f]{64}\z/

  postgres do
    table("agent_offer_leases")
    repo(Patchbay.Repo)
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)
    publish(:record, ["offers"], transform: fn _notification -> :offers_changed end)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:chain_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
    attribute(:market, :string, allow_nil?: false, public?: true, constraints: [match: @address])

    attribute(:transaction_hash, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @hash]
    )

    attribute(:log_index, :integer, allow_nil?: false, public?: true, constraints: [min: 0])
    attribute(:block_number, :integer, allow_nil?: false, public?: true, constraints: [min: 0])
    attribute(:block_hash, :string, allow_nil?: false, public?: true, constraints: [match: @hash])

    attribute(:placement_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
    attribute(:slot, :integer, allow_nil?: false, public?: true, constraints: [min: 0])
    attribute(:buyer, :string, allow_nil?: false, public?: true, constraints: [match: @address])

    attribute(:campaign_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @hash]
    )

    # USDC base units (six decimals), as the event carried them.
    attribute(:paid_usdc, :decimal, allow_nil?: false, public?: true, constraints: [min: 0])
    attribute(:starts_at, :utc_datetime, allow_nil?: false, public?: true)
    attribute(:ends_at, :utc_datetime, allow_nil?: false, public?: true)
    attribute(:nonce, :integer, allow_nil?: false, public?: true, constraints: [min: 1])

    create_timestamp(:inserted_at)
  end

  relationships do
    has_many :deliveries, Patchbay.Offers.Delivery
  end

  aggregates do
    count(:delivery_count, :deliveries, public?: true)
  end

  identities do
    identity(:unique_chain_event, [:chain_id, :transaction_hash, :log_index])
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :chain_id,
        :market,
        :transaction_hash,
        :log_index,
        :block_number,
        :block_hash,
        :placement_id,
        :slot,
        :buyer,
        :campaign_id,
        :paid_usdc,
        :starts_at,
        :ends_at,
        :nonce
      ])

      upsert?(true)
      upsert_identity(:unique_chain_event)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
      change(Patchbay.Offers.RecordOnce)
    end

    read :live do
      description("The market's leases whose term has not run out, newest first in each slot.")
      argument(:chain_id, :integer, allow_nil?: false)
      argument(:market, :string, allow_nil?: false)

      filter(expr(chain_id == ^arg(:chain_id) and market == ^arg(:market) and ends_at > now()))

      prepare(build(sort: [placement_id: :asc, slot: :asc, nonce: :desc]))
    end

    read :live_in do
      description("The live leases of these placements, newest first in each slot.")
      argument(:chain_id, :integer, allow_nil?: false)
      argument(:market, :string, allow_nil?: false)
      argument(:placement_ids, {:array, :integer}, allow_nil?: false)

      filter(
        expr(
          chain_id == ^arg(:chain_id) and market == ^arg(:market) and
            placement_id in ^arg(:placement_ids) and ends_at > now()
        )
      )

      prepare(build(sort: [placement_id: :asc, slot: :asc, nonce: :desc]))
    end

    read :in_blocks do
      argument(:chain_id, :integer, allow_nil?: false)
      argument(:market, :string, allow_nil?: false)
      argument(:from, :integer, allow_nil?: false)
      argument(:to, :integer, allow_nil?: false)

      filter(
        expr(
          chain_id == ^arg(:chain_id) and market == ^arg(:market) and
            block_number >= ^arg(:from) and block_number <= ^arg(:to)
        )
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
end
