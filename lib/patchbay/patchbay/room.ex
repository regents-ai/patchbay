defmodule Patchbay.Patchbay.Room do
  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Patchbay,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias Patchbay.Patchbay.Types.{GoalKind, RoomStatus}

  postgres do
    table("rooms")
    repo(Patchbay.Repo)

    references do
      reference(:last_failed_invocation, match_with: [id: :room_id])
      reference(:active_repair_proposal, match_with: [id: :room_id])
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    # `topic/1` below is these same two parts joined the same way, so a reset
    # lands on the channel every page open on the room is already listening to.
    publish(:reset_demo, ["patchbay:room", :id], transform: &__MODULE__.reset_message/1)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 100, match: ~r/\A[A-Za-z0-9_-]+\z/)
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
    attribute(:invocation_epoch, :integer, allow_nil?: false, public?: true, default: 0)
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

    belongs_to :active_repair_proposal, Patchbay.Patchbay.RepairProposal,
      allow_nil?: true,
      public?: true

    # The call the room is showing. A room's calls are its evidence and none of
    # them is ever removed, so the newest one is the one on the page.
    has_one :latest_invocation, Patchbay.Patchbay.Invocation do
      public?(true)
      from_many?(true)
      sort(started_at: :desc)
    end

    # The tool this room is offering right now. A room holds exactly one
    # revision in the desired state, and its own generation names which.
    has_one :desired_tool_revision, Patchbay.Patchbay.ToolRevision do
      public?(true)
      filter(expr(status == :desired and generation == parent(desired_tool_generation)))
    end
  end

  actions do
    defaults([:read, :destroy])

    read :for_update do
      prepare(build(lock: :for_update))
    end

    # Rooms nobody used are reaped so a crawler or a retry loop cannot fill the
    # database. A room that holds an invocation is somebody's evidence and is
    # never swept up by this, and neither is a room whose visitor has been seen
    # inside the window: reading a room does not touch the room row itself.
    read :idle_and_unused do
      argument(:untouched_since, :utc_datetime_usec, allow_nil?: false)

      filter(
        expr(
          updated_at < ^arg(:untouched_since) and
            not exists(invocations, true) and
            not exists(browser_sessions, last_seen_at >= ^arg(:untouched_since))
        )
      )
    end

    create :create_seeded_room do
      accept([])

      # Each visitor gets their own room, so the caller names it. Everything
      # else about the room comes from the checked-in fixture.
      argument :slug, :string do
        allow_nil?(false)
        constraints(min_length: 1, max_length: 100, match: ~r/\A[A-Za-z0-9_-]+\z/)
      end

      change({Patchbay.Patchbay.Changes.SeedRoom, []})
      change(set_attribute(:slug, arg(:slug)))

      # The room and the generation-1 tool it offers are one unit; a room that
      # exists without its tool would render as a broken page.
      change(
        after_action(fn _changeset, room, context ->
          Patchbay.Patchbay.Fixtures.revision_attributes(room.id)
          |> Map.delete(:contract_sha256)
          |> Patchbay.Patchbay.create_tool_revision!(Ash.Context.to_opts(context))

          {:ok, room}
        end)
      )
    end

    update :update_source do
      accept([:source_markdown])
      require_atomic?(false)

      validate attribute_equals(:status, :ready) do
        message(
          "The Source Skill is locked while this room is working. " <>
            "Reset the demo to edit it again."
        )
      end

      change(
        {Patchbay.Patchbay.Changes.RecomputeDigest,
         source_attribute: :source_markdown, digest_attribute: :source_sha256}
      )
    end

    update :apply_candidate do
      accept([:candidate_markdown])
      require_atomic?(false)
      validate(present(:candidate_markdown))
      validate(match(:candidate_markdown, ~r/\S/))

      change(
        {Patchbay.Patchbay.Changes.RecomputeDigest,
         source_attribute: :candidate_markdown, digest_attribute: :candidate_sha256}
      )

      change(optimistic_lock(:ui_revision))
    end

    # A failure is recorded wherever a tool call's verification lands, so it
    # names every status a call can be answered from. The repair statuses it
    # leaves out are the ones the repair writes while it holds the room lock,
    # where no verification can interleave.
    update :record_failure do
      accept([:last_failed_invocation_id])

      validate(
        one_of(:status, [
          :ready,
          :failed,
          :diagnosing,
          :awaiting_approval,
          :repaired,
          :retrying,
          :verified,
          :error
        ])
      )

      change(set_attribute(:status, :failed))
    end

    # The page marks the room as diagnosing the moment the owner asks, and the
    # planner marks it again once it holds the lock, so re-entry is legal.
    update :begin_diagnosis do
      accept([])
      validate(one_of(:status, [:failed, :diagnosing]))
      change(set_attribute(:status, :diagnosing))
    end

    update :mark_repair_ready do
      accept([])
      validate(attribute_equals(:status, :diagnosing))
      change(set_attribute(:status, :repair_ready))
    end

    update :await_approval do
      public?(false)
      accept([])
      validate(attribute_equals(:status, :repair_ready))
      change(set_attribute(:status, :awaiting_approval))
    end

    update :mark_repair_failed do
      public?(false)
      accept([])
      validate(attribute_equals(:status, :diagnosing))
      change(set_attribute(:status, :error))
    end

    update :begin_publication do
      accept([])
      validate(attribute_equals(:status, :awaiting_approval))
      change(set_attribute(:status, :publishing))
    end

    update :mark_repaired do
      accept([])
      validate(attribute_equals(:status, :publishing))
      change(set_attribute(:status, :repaired))
    end

    update :begin_retry do
      accept([])
      validate(attribute_equals(:status, :repaired))
      change(set_attribute(:status, :retrying))
    end

    update :mark_verified do
      accept([])
      validate(attribute_equals(:status, :retrying))
      change(set_attribute(:status, :verified))
    end

    update :set_desired_tool_generation do
      public?(false)
      accept([])
      argument(:generation, :integer, allow_nil?: false, public?: false)
      change(set_attribute(:desired_tool_generation, arg(:generation)))
    end

    update :set_active_repair_proposal do
      public?(false)
      accept([])
      argument(:proposal_id, :uuid, allow_nil?: true, public?: false)
      change(set_attribute(:active_repair_proposal_id, arg(:proposal_id)))
    end

    update :reset_demo do
      accept([])
      require_atomic?(false)
      change(Patchbay.Patchbay.Changes.ResetRoom)
    end
  end

  policies do
    # The hackathon room is intentionally public: reads are open, and so are the
    # writes the room page and the repair services make by name. Destroying a
    # room and the three status moves the publisher and the planner own are
    # named by no policy, so only a caller that skips authorization deliberately
    # can reach them.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([
             :create_seeded_room,
             :update_source,
             :apply_candidate,
             :record_failure,
             :begin_diagnosis,
             :mark_repair_ready,
             :mark_repair_failed,
             :begin_publication,
             :mark_repaired,
             :begin_retry,
             :mark_verified,
             :reset_demo
           ]) do
      authorize_if(always())
    end
  end

  @doc """
  The channel everything watching one room listens on: the open page, and
  whatever tells it that something changed from outside its own process.
  """
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(room_id) when is_binary(room_id), do: "patchbay:room:#{room_id}"

  @doc """
  What the room's channel carries when the room is put back to its seed.

  The epoch travels with it, so a page can tell a reset it has already applied
  from one made somewhere else.
  """
  @spec reset_message(Ash.Notifier.Notification.t()) ::
          {:patchbay_room_reset, Ash.UUID.t(), integer()}
  def reset_message(%Ash.Notifier.Notification{data: room}),
    do: {:patchbay_room_reset, room.id, room.invocation_epoch}
end
