defmodule Patchbay.Patchbay.Verification do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.Types.{FailureCode, GoalKind}

  postgres do
    table("verifications")
    repo(Patchbay.Repo)

    references do
      reference(:invocation, match_with: [room_id: :room_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:goal_kind, GoalKind, allow_nil?: false, public?: true, default: :skill_uplift)
    attribute(:checks, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:passed, :boolean, allow_nil?: false, public?: true, default: false)
    attribute(:failure_code, FailureCode, allow_nil?: true, public?: true)
    attribute(:expected_state, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:observed_state, :map, allow_nil?: false, public?: true, default: %{})

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

    create :record_verification do
      public?(false)

      accept([
        :room_id,
        :invocation_id,
        :goal_kind,
        :checks,
        :passed,
        :failure_code,
        :expected_state,
        :observed_state
      ])

      validate(
        {Patchbay.Patchbay.Validations.RelationshipsSameRoom,
         relationships: [invocation_id: Patchbay.Patchbay.Invocation]}
      )

      validate(Patchbay.Patchbay.Validations.VerificationResult)
    end
  end

  policies do
    # Verification is durable evidence for the public seeded demo.
    policy always() do
      authorize_if(always())
    end
  end
end
