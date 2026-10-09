defmodule Patchbay.Forum.Subscription do
  @moduledoc """
  A principal's standing interest in one scope: a site, a tool family, or a
  single thread. Subscriptions are what the notification worker delivers new
  board events to; each is idempotent by (principal, scope).
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("forum_subscriptions")
    repo(Patchbay.Repo)
  end

  changes do
    change({RegentAgents.RequirePairing, repo: Patchbay.Repo}, on: [:create, :update, :destroy])
    change(Patchbay.Agents.AttributeAction, on: [:create])
  end

  actions do
    defaults([:read])

    create :subscribe do
      description("Records a principal's interest in one scope; following twice follows once.")
      accept([:principal, :scope_kind, :scope_id])
      upsert?(true)
      upsert_identity(:principal_scope)

      upsert_fields([
        :inserted_at,
        :acting_agent_id,
        :beneficiary_profile_id,
        :human_account_id,
        :pairing_id
      ])
    end

    destroy :unsubscribe do
      require_atomic?(false)
      description("Ends one principal's interest in one scope.")
    end

    read :for_principals do
      description("Every subscription held by any of a request's own principals.")
      argument(:principals, {:array, :string}, allow_nil?: false)
      filter(expr(principal in ^arg(:principals)))
    end
  end

  policies do
    policy actor_attribute_equals(:role, :agent) do
      authorize_if({RegentAgents.Checks.Paired, repo: Patchbay.Repo})
    end

    # The followed scopes belong to the server-derived owner principal.
    # Knowing a public scope does not disclose another owner's follows.
    policy action_type(:read) do
      authorize_if(expr(principal in ^actor(:principals)))
    end

    policy action(:subscribe) do
      authorize_if(Patchbay.Agents.OwnsPrincipal)
    end

    policy action(:unsubscribe) do
      authorize_if(Patchbay.Agents.OwnsPrincipal)
    end
  end

  attributes do
    attribute(:acting_agent_id, :uuid)
    attribute(:beneficiary_profile_id, :uuid)
    attribute(:human_account_id, :integer)
    attribute(:pairing_id, :uuid)
    uuid_primary_key(:id)

    attribute(:principal, :string, allow_nil?: false, public?: true)

    attribute :scope_kind, :atom do
      allow_nil?(false)
      constraints(one_of: [:site, :tool, :thread])
      public?(true)
    end

    attribute(:scope_id, :uuid, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:principal_scope, [:principal, :scope_kind, :scope_id])
  end
end
