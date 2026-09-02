defmodule Patchbay.Forum.RepairAttempt do
  @moduledoc """
  Patchbay's own record of what it did about one report.

  Reports and replies are what agents wrote, and both are append-only, so the
  work Patchbay does in response is kept here instead. One row stands for one
  report: claiming it is what stops the same report being worked twice, and its
  outcome is why a reply says what it says.

  The row also carries how far the work has got, so the room the report is about
  can show the repair happening instead of only its result: `phase` moves
  forward once per step and `phase_changed_at` says when it last moved. That is
  the one thing anything outside Patchbay's own worker reads here, and only the
  room the attempt was made for reads it.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias Patchbay.Forum.Types.RepairAttemptPhase
  alias Patchbay.Forum.Types.RepairAttemptStatus

  @max_detail_bytes 500
  @terminal_statuses [:published, :not_reproduced, :refused, :errored]

  postgres do
    table("forum_repair_attempts")
    repo(Patchbay.Repo)

    references do
      reference(:report, index?: true)
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    # `Patchbay.Patchbay.Room.topic/1` is these same two parts joined the same
    # way, so a step forward and the answer that ends the work both land on the
    # channel the open room page is already listening to. An attempt about a
    # page that has since been cleared away has no room to name, and nothing is
    # published for it.
    publish(:mark_phase, ["patchbay:room", :room_id], transform: &__MODULE__.phase_message/1)

    publish(:record_outcome, ["patchbay:room", :room_id],
      transform: &__MODULE__.replied_message/1
    )
  end

  attributes do
    uuid_primary_key(:id)

    # The room, the call, the proposal and the reply are named rather than
    # pointed at, for the same reason a report names its call: a room and its
    # evidence are cleared away in time, and this record outlives them.
    # A report outlives the room whose call it describes, so a report filed
    # about a page that has since been cleared away still gets an attempt and an
    # honest answer; it just has no room to name.
    attribute(:room_id, :uuid, allow_nil?: true)
    attribute(:invocation_id, :uuid, allow_nil?: false)
    attribute(:proposal_id, :uuid, allow_nil?: true)
    attribute(:reply_id, :uuid, allow_nil?: true)

    attribute(:status, RepairAttemptStatus, allow_nil?: false, default: :queued)

    # A page opened halfway through a repair reads these two and shows what a
    # page that watched the whole repair is showing.
    attribute(:phase, RepairAttemptPhase, allow_nil?: false, default: :queued)

    attribute(:phase_changed_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0
    )

    attribute :detail, :string do
      allow_nil?(true)
      constraints(max_length: @max_detail_bytes, trim?: false)
    end

    timestamps()
  end

  identities do
    # One report is worked once. A second claim on the same report is refused by
    # the database rather than by a check the worker could race past.
    identity(:unique_report, [:report_id], eager_check?: false)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false)
  end

  actions do
    defaults([:read])

    read :latest_for_invocation do
      description("""
      The most recent repair Patchbay actually started on one recorded call. A
      report it declined to work never left `:queued` and is not one of these.
      """)

      get?(true)

      argument(:invocation_id, :uuid, allow_nil?: false)

      filter(expr(invocation_id == ^arg(:invocation_id) and phase != :queued))
      prepare(build(sort: [inserted_at: :desc, id: :desc], limit: 1))
    end

    create :claim do
      description("Takes one report to work on, or fails because it is already taken.")
      accept([:report_id, :room_id, :invocation_id])
    end

    update :mark_running do
      description("The repair for this report has started.")
      accept([])
      change(set_attribute(:status, :running))
    end

    update :mark_phase do
      description("Moves the attempt on to the step the worker has just reached.")
      accept([])

      argument(:phase, RepairAttemptPhase, allow_nil?: false)

      change(set_attribute(:phase, arg(:phase)))
      change(set_attribute(:phase_changed_at, &DateTime.utc_now/0))
    end

    update :record_outcome do
      description("What came of this attempt, and the reply that says so.")
      accept([:status, :proposal_id, :reply_id, :detail])
      validate(one_of(:status, @terminal_statuses))
    end
  end

  policies do
    # There is no public way in. Patchbay's worker is the only caller, and it
    # says so at each call site by skipping authorization deliberately.
    policy always() do
      forbid_if(always())
    end
  end

  @doc """
  What the room's channel carries when an attempt reaches its next step.
  """
  @spec phase_message(Ash.Notifier.Notification.t()) ::
          {:patchbay_agent_progress, String.t() | nil, atom()}
  def phase_message(%Ash.Notifier.Notification{data: attempt}),
    do: {:patchbay_agent_progress, attempt.room_id, attempt.phase}

  @doc """
  What the room's channel carries when the report an attempt was made about has
  been answered.
  """
  @spec replied_message(Ash.Notifier.Notification.t()) ::
          {:patchbay_agent_replied, String.t() | nil, Ash.UUID.t()}
  def replied_message(%Ash.Notifier.Notification{data: attempt}),
    do: {:patchbay_agent_replied, attempt.room_id, attempt.report_id}

  @spec max_detail_bytes() :: pos_integer()
  def max_detail_bytes, do: @max_detail_bytes

  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal_statuses
end
