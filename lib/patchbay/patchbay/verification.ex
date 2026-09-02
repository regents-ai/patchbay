defmodule Patchbay.Patchbay.Verification do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.PostconditionVerifier
  alias Patchbay.Patchbay.Types.{FailureCode, GoalKind, VisibleState}

  # The verifier owns the check list, so the stored shape follows it rather than
  # repeating it.
  @check_fields Enum.map(PostconditionVerifier.required_checks(), &{&1, [type: :boolean]})

  postgres do
    table("verifications")
    repo(Patchbay.Repo)

    references do
      reference(:room, on_delete: :delete)
      reference(:invocation, match_with: [room_id: :room_id], on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:goal_kind, GoalKind, allow_nil?: false, public?: true, default: :skill_uplift)

    attribute :checks, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
      constraints(preserve_nil_values?: true, fields: @check_fields)
    end

    attribute(:passed, :boolean, allow_nil?: false, public?: true, default: false)
    attribute(:failure_code, FailureCode, allow_nil?: true, public?: true)
    attribute(:expected_state, VisibleState, allow_nil?: false, public?: true, default: %{})
    attribute(:observed_state, VisibleState, allow_nil?: false, public?: true, default: %{})

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_invocation, [:invocation_id], eager_check?: true)
  end

  relationships do
    belongs_to :room, Patchbay.Patchbay.Room, allow_nil?: false, public?: true
    belongs_to :invocation, Patchbay.Patchbay.Invocation, allow_nil?: false, public?: true
  end

  actions do
    defaults([:read])

    read :for_update do
      prepare(build(lock: :for_update))
    end

    create :record_verification do
      public?(false)

      # The observed state is the only evidence a caller supplies. Everything the
      # row concludes from it is derived here, so there is one producer of the
      # verdict rather than a caller and a checker that have to agree.
      accept([:room_id, :invocation_id, :goal_kind, :observed_state])

      change(Patchbay.Patchbay.Changes.DeriveVerificationResult)
    end
  end

  policies do
    # Verification is durable evidence for the public seeded demo: reads are
    # open, and recording one is the single named write.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:record_verification) do
      authorize_if(always())
    end
  end
end
