defmodule Patchbay.Offers.Placement do
  @moduledoc """
  One `PlacementCreated` event of Patchbay's market, exactly as the chain gave
  it, never rewritten: a place on a site's page Patchbay sells, its slots,
  each lease's length, the step a buyout must pay over a live lease, the
  floor price, and the admission policy every purchase in it is signed under.

  `source_origin` is what the placement is for: a listed site, or General or
  CVE incidents (`Patchbay.Offers.Source`). Patchbay's own placements name
  its page as their address (`metadata_uri`, ending in the site's address or
  the name), and it counts only when its hash is the placement's `source_id`,
  so the address cannot name a different one.
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
    table("agent_offer_placements")
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
    attribute(:source_id, :string, allow_nil?: false, public?: true, constraints: [match: @hash])
    attribute(:capacity, :integer, allow_nil?: false, public?: true, constraints: [min: 1])

    attribute(:duration_seconds, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]
    )

    attribute(:min_bump_bps, :integer, allow_nil?: false, public?: true, constraints: [min: 0])
    # USDC base units (six decimals), as the event carried them.
    attribute(:floor_usdc, :decimal, allow_nil?: false, public?: true, constraints: [min: 0])

    attribute(:policy_hash, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @hash]
    )

    attribute(:metadata_uri, :string,
      allow_nil?: false,
      public?: true,
      constraints: [allow_empty?: true, trim?: false]
    )

    attribute(:source_origin, :string, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at)
  end

  relationships do
    has_many :terminations, Patchbay.Offers.Termination do
      no_attributes?(true)
      validate_destination_attribute?(false)

      filter(
        expr(
          chain_id == parent(chain_id) and market == parent(market) and
            placement_id == parent(placement_id)
        )
      )
    end
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
        :source_id,
        :capacity,
        :duration_seconds,
        :min_bump_bps,
        :floor_usdc,
        :policy_hash,
        :metadata_uri,
        :source_origin
      ])

      upsert?(true)
      upsert_identity(:unique_chain_event)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
      change(Patchbay.Offers.RecordOnce)
    end

    read :open do
      description("The market's placements still open to buying, oldest first.")
      argument(:chain_id, :integer, allow_nil?: false)
      argument(:market, :string, allow_nil?: false)

      filter(
        expr(
          chain_id == ^arg(:chain_id) and market == ^arg(:market) and
            not exists(terminations, true)
        )
      )

      prepare(build(sort: [placement_id: :asc]))
    end

    read :open_for do
      description("The market's open placements for these sources, oldest first.")
      argument(:chain_id, :integer, allow_nil?: false)
      argument(:market, :string, allow_nil?: false)
      argument(:origins, {:array, :string}, allow_nil?: false)

      filter(
        expr(
          chain_id == ^arg(:chain_id) and market == ^arg(:market) and
            source_origin in ^arg(:origins) and not exists(terminations, true)
        )
      )

      prepare(build(sort: [placement_id: :asc]))
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
    # What the chain said is public.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
end
