defmodule Patchbay.Patchbay.RepairProposal do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias Patchbay.Patchbay.Types.{FailureCode, ProposalStatus}

  # The canary decides these nine checks itself; they are deliberately not the
  # visible-postcondition set, because a canary runs before anything is on
  # screen.
  @canary_checks [
    :adapter_allowlisted,
    :postcondition_allowlisted,
    :candidate_present,
    :source_unchanged,
    :candidate_digest_changed,
    :frontmatter_valid,
    :identity_preserved,
    :output_contract_valid,
    :ui_revision_advanced
  ]

  # A canary can fail a check the visible-postcondition verifier does not make,
  # which is what its own code covers. Listing the atoms here is what lets a
  # stored code be read back as an atom.
  @canary_failure_codes [:CANARY_FAILED | FailureCode.values()]

  @token_counters [
    preserve_nil_values?: true,
    fields: [
      input_tokens: [type: :integer],
      output_tokens: [type: :integer],
      total_tokens: [type: :integer]
    ]
  ]

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

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    # `Patchbay.Patchbay.Room.topic/1` is these same two parts joined the same
    # way, so a published repair lands on the channel the open room page is
    # already listening to, whoever approved it.
    publish(:publish, ["patchbay:room", :room_id], transform: &__MODULE__.published_message/1)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:candidate_tool_revision_id, :uuid, allow_nil?: true, public?: true)
    attribute(:status, ProposalStatus, allow_nil?: false, public?: true, default: :requested)
    attribute(:root_cause, :string, allow_nil?: false, public?: true)
    attribute(:repair_plan, :map, allow_nil?: false, public?: true, default: %{})
    attribute(:contract_diff, :map, allow_nil?: false, public?: true, default: %{})

    attribute :canary_result, :map do
      allow_nil?(false)
      public?(true)
      default(%{})

      constraints(
        preserve_nil_values?: true,
        fields: [
          passed: [type: :boolean],
          checks: [
            type: :map,
            constraints: [
              preserve_nil_values?: true,
              fields: Enum.map(@canary_checks, &{&1, [type: :boolean]})
            ]
          ],
          failure_code: [type: :atom, constraints: [one_of: @canary_failure_codes]],
          candidate_sha256: [type: :string]
        ]
      )
    end

    attribute(:risk_notes, {:array, :string}, allow_nil?: false, public?: true, default: [])
    attribute(:model, :string, allow_nil?: false, public?: true)
    attribute(:model_response_id, :string, allow_nil?: false, public?: true)
    attribute(:prompt_version, :string, allow_nil?: false, public?: true)

    # Bounded token counters from the candidate-generation and repair-plan
    # calls. Never any response text.
    attribute :usage, :map do
      allow_nil?(false)
      public?(true)
      default(%{})

      constraints(
        preserve_nil_values?: true,
        fields: [
          candidate: [type: :map, constraints: @token_counters],
          repair_plan: [type: :map, constraints: @token_counters]
        ]
      )
    end

    attribute(:input_sha256, :string, allow_nil?: false, public?: true)
    attribute(:approved_by, :string, allow_nil?: true, public?: true)
    attribute(:approved_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:rejected_at, :utc_datetime_usec, allow_nil?: true, public?: true)
    attribute(:published_at, :utc_datetime_usec, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:unique_id_per_room, [:id, :room_id], eager_check?: false)
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

    read :for_update do
      prepare(build(lock: :for_update))
    end

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
    end

    update :mark_canary_passed do
      accept([:canary_result])
      require_atomic?(false)
      validate(attribute_equals(:status, :requested))
      validate(Patchbay.Patchbay.Validations.CanaryResult)
      change(set_attribute(:status, :ready_for_approval))
    end

    update :mark_canary_failed do
      accept([:canary_result])
      validate(attribute_equals(:status, :requested))
      change(set_attribute(:status, :canary_failed))
    end

    update :approve do
      accept([])
      # A string argument is trimmed and an empty one becomes nil, so naming an
      # approver is what `allow_nil?: false` asks for: no blank name gets through.
      argument(:approved_by, :string, allow_nil?: false)
      require_atomic?(false)
      validate(attribute_equals(:status, :ready_for_approval))
      validate(Patchbay.Patchbay.Validations.CanaryPassed)
      validate(Patchbay.Patchbay.Validations.RepairsCurrentFailure)
      change(set_attribute(:status, :approved))
      change(set_attribute(:approved_by, arg(:approved_by)))
      change(set_attribute(:approved_at, &DateTime.utc_now/0))
    end

    # The owner rejects a repair that is waiting on them; a demo reset rejects
    # whatever a run left behind, which is any proposal that never reached a
    # terminal status.
    update :reject do
      accept([])
      validate(one_of(:status, [:requested, :canary_failed, :ready_for_approval, :approved]))
      change(set_attribute(:status, :rejected))
      change(set_attribute(:rejected_at, &DateTime.utc_now/0))
    end

    update :publish do
      accept([])
      require_atomic?(false)
      validate(attribute_equals(:status, :approved))
      validate(Patchbay.Patchbay.Validations.CanaryPassed)
      change(set_attribute(:status, :published))
      change(set_attribute(:published_at, &DateTime.utc_now/0))
    end
  end

  policies do
    # The record is visible in the seeded public room, so reads are open. Each
    # step of the proposal's life is a named action, approval included, so
    # nothing can move a proposal sideways.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([
             :create_proposal,
             :mark_canary_passed,
             :mark_canary_failed,
             :approve,
             :reject,
             :publish
           ]) do
      authorize_if(always())
    end
  end

  @doc "The checks a canary must record, all true, before a repair may be approved."
  @spec canary_checks() :: [atom()]
  def canary_checks, do: @canary_checks

  @doc """
  What the room's channel carries when a repair is published into it.
  """
  @spec published_message(Ash.Notifier.Notification.t()) ::
          {:patchbay_agent_published, Ash.UUID.t(), Ash.UUID.t()}
  def published_message(%Ash.Notifier.Notification{data: proposal}),
    do: {:patchbay_agent_published, proposal.room_id, proposal.id}
end
