defmodule Patchbay.Offers.Termination do
  @moduledoc """
  One `PlacementTerminated` event of Patchbay's market, exactly as the chain
  gave it, never rewritten: the placement closed to buying, and the moment
  every lease in it is refunded from.
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
    table("agent_offer_terminations")
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
    attribute(:terminated_at, :utc_datetime, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
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
        :terminated_at
      ])

      upsert?(true)
      upsert_identity(:unique_chain_event)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
      change(Patchbay.Offers.RecordOnce)
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
