defmodule Patchbay.Patchbay.Room do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Patchbay.Types.{GoalKind, RoomStatus}

  postgres do
    table("rooms")
    repo(Patchbay.Repo)

    references do
      reference(:last_failed_invocation, match_with: [id: :room_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 100)
    end

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 200)
    end

    attribute :status, RoomStatus do
      allow_nil?(false)
      public?(true)
      default(:ready)
    end

    attribute :goal_kind, GoalKind do
      allow_nil?(false)
      public?(true)
      default(:skill_uplift)
    end

    attribute(:goal_text, :string, allow_nil?: false, public?: true)

    attribute :source_markdown, :string do
      allow_nil?(false)
      public?(true)
      sensitive?(true)
      constraints(max_length: 65_536, trim?: false)
    end

    attribute :source_sha256, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 64, max_length: 64)
    end

    attribute :candidate_markdown, :string do
      allow_nil?(true)
      public?(true)
      sensitive?(true)
      constraints(max_length: 65_536, trim?: false)
    end

    attribute :candidate_sha256, :string do
      allow_nil?(true)
      public?(true)
      constraints(min_length: 64, max_length: 64)
    end

    attribute(:ui_revision, :integer, allow_nil?: false, public?: true, default: 0)
    attribute(:desired_tool_generation, :integer, allow_nil?: false, public?: true, default: 1)
    attribute(:seed_version, :string, allow_nil?: false, public?: true)
    attribute(:last_failed_invocation_id, :uuid, allow_nil?: true, public?: true)
    attribute(:active_repair_proposal_id, :uuid, allow_nil?: true, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_slug, [:slug], eager_check?: true)
  end

  relationships do
    has_many :browser_sessions, Patchbay.Patchbay.BrowserSession
    has_many :tool_revisions, Patchbay.Patchbay.ToolRevision
    has_many :invocations, Patchbay.Patchbay.Invocation
    has_many :repair_proposals, Patchbay.Patchbay.RepairProposal
    has_many :verifications, Patchbay.Patchbay.Verification
    has_many :room_events, Patchbay.Patchbay.RoomEvent

    belongs_to :last_failed_invocation, Patchbay.Patchbay.Invocation,
      allow_nil?: true,
      public?: true
  end

  actions do
    defaults([:read])

    create :create_seeded_room do
      accept([])
      change({Patchbay.Patchbay.Changes.SeedRoom, []})
    end

    update :update_source do
      accept([:source_markdown])
      require_atomic?(false)

      change(
        {Patchbay.Patchbay.Changes.RecomputeDigest,
         source_attribute: :source_markdown, digest_attribute: :source_sha256}
      )
    end

    update :apply_candidate do
      accept([:candidate_markdown])
      require_atomic?(false)
      validate(present(:candidate_markdown))
      change(Patchbay.Patchbay.Changes.ApplyCandidate)
      change(optimistic_lock(:ui_revision))
    end

    update :record_failure do
      accept([:last_failed_invocation_id])
      require_atomic?(false)
      validate(Patchbay.Patchbay.Validations.LastFailedInvocationSameRoom)
      change(set_attribute(:status, :failed))
    end

    update :begin_diagnosis do
      accept([])
      change(set_attribute(:status, :diagnosing))
    end

    update :mark_repair_ready do
      accept([])
      change(set_attribute(:status, :repair_ready))
    end

    update :begin_publication do
      accept([])
      change(set_attribute(:status, :publishing))
    end

    update :mark_repaired do
      accept([])
      change(set_attribute(:status, :repaired))
    end

    update :mark_verified do
      accept([])
      change(set_attribute(:status, :verified))
    end

    update :set_desired_tool_generation do
      public?(false)
      accept([])
      argument(:generation, :integer, allow_nil?: false, public?: false)
      change(set_attribute(:desired_tool_generation, arg(:generation)))
    end

    update :reset_demo do
      accept([])
      require_atomic?(false)
      change(Patchbay.Patchbay.Changes.ResetRoom)
    end
  end

  policies do
    # The hackathon room is intentionally public; authorization still remains
    # explicit so a future private-room policy cannot accidentally be skipped.
    policy always() do
      authorize_if(always())
    end
  end
end
