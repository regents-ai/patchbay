defmodule Patchbay.Patchbay.RepairProposal do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.Types.ProposalStatus

  postgres do
    table("repair_proposals")
    repo(Patchbay.Repo)

    references do
      reference(:room, on_delete: :delete)
      reference(:source_invocation, match_with: [room_id: :room_id], on_delete: :delete)
      reference(:source_tool_revision, match_with: [room_id: :room_id], on_delete: :delete)
      reference(:candidate_tool_revision, match_with: [room_id: :room_id], on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:candidate_tool_revision_id, :uuid, allow_nil?: true, public?: true)
    attribute(:status, ProposalStatus, allow_nil?: false, public?: true, default: :requested)
    attribute(:root_cause, :string, allow_nil?: false, public?: true)
    attribute(:repair_plan, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:contract_diff, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:canary_result, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:risk_notes, {:array, :string}, allow_nil?: false, public?: true, default: [])
    attribute(:model, :string, allow_nil?: false, public?: true)
    attribute(:model_response_id, :string, allow_nil?: false, public?: true)
    attribute(:prompt_version, :string, allow_nil?: false, public?: true)

    # Bounded token counters from the candidate-generation and repair-plan
    # calls. Never any response text.
    attribute(:usage, :map, allow_nil?: false, public?: true, default: %{})

    attribute(:input_sha256, :string, allow_nil?: false, public?: true)
    attribute(:approved_by, :string, allow_nil?: true, public?: true)
    attribute(:approved_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:rejected_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:published_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  relationships do
    belongs_to :room, Patchbay.Patchbay.Room, allow_nil?: false, public?: true
    belongs_to :source_invocation, Patchbay.Patchbay.Invocation, allow_nil?: false, public?: true

    belongs_to :source_tool_revision, Patchbay.Patchbay.ToolRevision,
      allow_nil?: false,
      public?: true

    belongs_to :candidate_tool_revision, Patchbay.Patchbay.ToolRevision,
      allow_nil?: true,
      public?: true
  end

  actions do
    defaults([:read])

    create :create_proposal do
      accept([
        :room_id,
        :source_invocation_id,
        :source_tool_revision_id,
        :candidate_tool_revision_id,
        :root_cause,
        :repair_plan,
        :contract_diff,
        :canary_result,
        :risk_notes,
        :model,
        :model_response_id,
        :prompt_version,
        :usage,
        :input_sha256
      ])

      validate(
        {Patchbay.Patchbay.Validations.RelationshipsSameRoom,
         relationships: [
           source_invocation_id: Patchbay.Patchbay.Invocation,
           source_tool_revision_id: Patchbay.Patchbay.ToolRevision,
           candidate_tool_revision_id: Patchbay.Patchbay.ToolRevision
         ]}
      )
    end

    update :mark_canary_passed do
      accept([:canary_result])
      require_atomic?(false)
      validate(Patchbay.Patchbay.Validations.CanaryResult)
      change(set_attribute(:status, :ready_for_approval))
    end

    update :mark_canary_failed do
      accept([:canary_result])
      change(set_attribute(:status, :canary_failed))
    end

    update :approve do
      accept([])
      argument(:approved_by, :string, allow_nil?: false)
      require_atomic?(false)
      change(Patchbay.Patchbay.Changes.ApproveProposal)
    end

    update :reject do
      accept([])
      change(set_attribute(:status, :rejected))
      change(set_attribute(:rejected_at, &DateTime.utc_now/0))
    end

    update :publish do
      accept([])
      require_atomic?(false)
      validate(attribute_equals(:status, :approved))
      validate(Patchbay.Patchbay.Validations.PublishableProposal)
      change(set_attribute(:status, :published))
      change(set_attribute(:published_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # The record is visible in the seeded public room; approval remains a
    # named action so the LiveView can make the human decision explicit.
    policy always() do
      authorize_if(always())
    end
  end
end
