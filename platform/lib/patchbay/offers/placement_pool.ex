defmodule Patchbay.Offers.PlacementPool do
  @moduledoc """
  One pool Patchbay chose for a placement (`Patchbay.Offers.Pool`): the
  placement shows campaigns from its chosen pools, and any campaign Patchbay
  accepts while it has none. The placement is named as the
  market names it, by chain, market and placement id. Choosing a pool already
  chosen leaves it as it is.

  Only a moderator reads, chooses or drops pools for a placement; Patchbay's
  own serving and admission read them as the system.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @address ~r/\A0x[0-9a-f]{40}\z/

  postgres do
    table("agent_offer_placement_pools")
    repo(Patchbay.Repo)

    references do
      reference(:pool, on_delete: :delete)
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)
    publish_all(:create, ["offers"], transform: fn _notification -> :offers_changed end)
    publish_all(:destroy, ["offers"], transform: fn _notification -> :offers_changed end)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:chain_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
    attribute(:market, :string, allow_nil?: false, public?: true, constraints: [match: @address])
    attribute(:placement_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :pool, Patchbay.Offers.Pool do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:unique_choice, [:chain_id, :market, :placement_id, :pool_id])
  end

  actions do
    defaults([:read, :destroy])

    create :choose do
      accept([:chain_id, :market, :placement_id, :pool_id])
      upsert?(true)
      upsert_identity(:unique_choice)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
    end

    read :for_placements do
      argument(:chain_id, :integer, allow_nil?: false)
      argument(:market, :string, allow_nil?: false)
      argument(:placement_ids, {:array, :integer}, allow_nil?: false)

      filter(
        expr(
          chain_id == ^arg(:chain_id) and market == ^arg(:market) and
            placement_id in ^arg(:placement_ids)
        )
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :system))
      authorize_if(Patchbay.Checks.Moderator)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(Patchbay.Checks.Moderator)
    end
  end
end
