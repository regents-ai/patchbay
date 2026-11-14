defmodule Patchbay.Offers.PoolMember do
  @moduledoc """
  One advertiser wallet on a pool's membership list
  (`Patchbay.Offers.Pool`). Adding a wallet already there leaves it as it is.
  Only a moderator reads, adds or removes members; Patchbay's own serving
  reads them as the system.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  @address ~r/\A0x[0-9a-f]{40}\z/

  postgres do
    table("agent_offer_pool_members")
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
    attribute(:wallet, :string, allow_nil?: false, public?: true, constraints: [match: @address])
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :pool, Patchbay.Offers.Pool do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:unique_member, [:pool_id, :wallet])
  end

  actions do
    defaults([:read, :destroy])

    create :add do
      accept([:pool_id, :wallet])
      upsert?(true)
      upsert_identity(:unique_member)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
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
