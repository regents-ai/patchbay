defmodule Patchbay.Offers.AdvertiserRule do
  @moduledoc """
  Patchbay's word on one advertiser wallet: `:accepted` or `:blocked`. A
  wallet Patchbay has not accepted is not admitted to buy, and a blocked
  wallet never is, even if it is also accepted.

  Only Patchbay sets or removes a rule (`mix patchbay.offers`, as the system
  actor). A signed-in person reads the rules on their own wallets, which is
  how their purchase is checked.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @address ~r/\A0x[0-9a-f]{40}\z/

  postgres do
    table("agent_offer_advertiser_rules")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:wallet, :string, allow_nil?: false, public?: true, constraints: [match: @address])

    attribute(:verdict, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:accepted, :blocked]]
    )

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_rule, [:wallet, :verdict])
  end

  actions do
    defaults([:read, :destroy])

    # Setting a rule already there leaves it as it is.
    create :set do
      accept([:wallet, :verdict])
      upsert?(true)
      upsert_identity(:unique_rule)
      upsert_fields([])
      upsert_condition(expr(false))
      return_skipped_upsert?(true)
    end

    read :for_wallets do
      argument(:wallets, {:array, :string}, allow_nil?: false)
      filter(expr(wallet in ^arg(:wallets)))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :system))
      authorize_if(expr(wallet in ^actor(:wallet_addresses)))
    end

    policy action_type([:create, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
end
