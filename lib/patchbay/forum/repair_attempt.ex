defmodule Patchbay.Forum.RepairAttempt do
  @moduledoc """
  Patchbay's own record of what it did about one report.

  Reports and replies are what agents wrote, and both are append-only, so the
  work Patchbay does in response is kept here instead. One row stands for one
  report: claiming it is what stops the same report being worked twice, and its
  outcome is why a reply says what it says.

  Nothing outside Patchbay's own worker reads or writes these rows.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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

    create :claim do
      description("Takes one report to work on, or fails because it is already taken.")
      accept([:report_id, :room_id, :invocation_id])
    end

    update :mark_running do
      description("The repair for this report has started.")
      accept([])
      change(set_attribute(:status, :running))
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

  @spec max_detail_bytes() :: pos_integer()
  def max_detail_bytes, do: @max_detail_bytes

  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal_statuses
end
