defmodule Patchbay.Identity.HumanAccount do
  @moduledoc """
  A person's shared Regent account, in the table Regents owns. A Privy
  sign-in records the person here as every Regent site does, so their Points
  and paired agents follow them from site to site.
  """

  use Ash.Resource,
    domain: Patchbay.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("platform_human_users")
    schema("regent_names")
    repo(Patchbay.Repo)
    migrate?(false)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:privy_user_id, :string, allow_nil?: false, sensitive?: true)
    attribute(:wallet_address, :string, sensitive?: true)
    attribute(:wallet_addresses, {:array, :string}, default: [], sensitive?: true)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_privy_user_id, [:privy_user_id])
  end

  actions do
    read :by_privy_did do
      get?(true)
      argument(:privy_did, :string, allow_nil?: false)
      filter(expr(privy_user_id == ^arg(:privy_did)))
    end

    read :points_account do
      get?(true)
      argument(:id, :integer, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    create :register_verified do
      accept([:privy_user_id, :wallet_address, :wallet_addresses])
      upsert?(true)
      upsert_identity(:unique_privy_user_id)
      upsert_fields([])
    end

    update :refresh_verified do
      accept([:wallet_address, :wallet_addresses])
      require_atomic?(false)
      validate(present(:wallet_addresses))
    end
  end

  policies do
    policy action([:by_privy_did, :points_account, :register_verified, :refresh_verified]) do
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end
end
