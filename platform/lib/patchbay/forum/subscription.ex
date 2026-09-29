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

  actions do
    defaults([:read])

    create :subscribe do
      description("Records a principal's interest in one scope; following twice follows once.")
      accept([:principal, :scope_kind, :scope_id])
      upsert?(true)
      upsert_identity(:principal_scope)
      upsert_fields([:inserted_at])
    end

    destroy :unsubscribe do
      description("Ends one principal's interest in one scope.")
    end

    read :for_principals do
      description("Every subscription held by any of a request's own principals.")
      argument(:principals, {:array, :string}, allow_nil?: false)
      filter(expr(principal in ^arg(:principals)))
    end
  end

  policies do
    # Subscriptions are keyed by a server-derived principal, not an actor, so
    # writes arrive through the API and browser doors that already hold the
    # session; the read here is open because the scopes are already public.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:subscribe) do
      authorize_if(always())
    end

    policy action(:unsubscribe) do
      authorize_if(always())
    end
  end

  attributes do
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
