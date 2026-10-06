defmodule Patchbay.Offers.BidWindow do
  @moduledoc """
  Two seconds in which bids for one slot and one lane compete.

  The first qualifying bid opens a window that closes two seconds later.
  Every bid accepted before then competes against the same committed
  baseline (the active owner's bid for `:immediate`, the committed next
  leader's for `:next_period`), not against each other. When it settles, the
  highest fully held bid wins, ties going to the earliest accepted, and every
  other bid's hold returns in full.

  A window names the state it was opened against: the slot's active
  generation and placement, and for the next-period lane the slot's next
  revision. If that state has moved on by settlement, every bid in the
  window is returned unfilled.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Offers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban],
    notifiers: [Ash.Notifier.PubSub]

  # A window's outcome tells open Offers pages to read again, on the slots'
  # own topic, after it commits.
  pub_sub do
    module(Phoenix.PubSub)
    name(Patchbay.PubSub)

    publish(:close, ["offers:markets"], transform: &Patchbay.Offers.Slot.changed_message/1)
  end

  # A window is settled by the job queued for its closing time, in the same
  # transaction that opened it. The minute sweep settles any whose job ran
  # early or was lost. Settling a window settles everything due in its slot.
  oban do
    triggers do
      trigger :settle do
        action(:settle)
        queue(:offers_settlement)
        where(expr(state == :open and closes_at <= now()))
        max_attempts(5)
        lock_for_update?(false)
        worker_module_name(Patchbay.Offers.BidWindow.Workers.Settle)
        scheduler_module_name(Patchbay.Offers.BidWindow.Schedulers.Settle)
      end
    end
  end

  postgres do
    table("offer_bid_windows")
    repo(Patchbay.Repo)

    check_constraints do
      check_constraint(:closes_at, "offer_bid_windows_two_seconds",
        check: "closes_at = opened_at + interval '2 seconds'",
        message: "a window is open for exactly two seconds"
      )

      check_constraint(:state, "offer_bid_windows_terminal_shape",
        check:
          "(state = 'open') = (settled_at IS NULL) AND (winner_bid_id IS NULL OR state = 'won')",
        message: "only a settled window has a settlement time, and only a won window has a winner"
      )
    end

    # One open window per slot and lane.
    identity_wheres_to_sql(one_open_per_lane: "state = 'open'")

    custom_indexes do
      index([:closes_at], where: "state = 'open'")
      # Lets a bid's foreign key insist it is in the same slot and lane as its window.
      index([:id, :slot_id, :lane], unique: true, name: "offer_bid_windows_id_slot_lane")
    end

    references do
      reference(:slot, on_delete: :restrict)
      reference(:target_placement, on_delete: :restrict)
      reference(:winner_bid, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:lane, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:immediate, :next_period]]
    )

    # The slot as this window found it.
    attribute(:target_generation, :integer, allow_nil?: false, public?: true)
    attribute(:target_next_revision, :integer, allow_nil?: false, public?: true)

    # The committed amount bids had to beat by 10%, or nil when they only
    # had to meet the opening minimum.
    attribute(:baseline_minor, :integer, allow_nil?: true, public?: true)

    attribute(:opened_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:closes_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    # `:open` while bids may join or wait for settlement; then `:won`, or
    # `:unfilled` when no bid could win, or `:stale` when the slot moved on.
    attribute(:state, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      constraints: [one_of: [:open, :won, :unfilled, :stale]]
    )

    attribute(:settled_at, :utc_datetime_usec, allow_nil?: true, public?: true)
  end

  identities do
    identity(:one_open_per_lane, [:slot_id, :lane], where: expr(state == :open))
  end

  relationships do
    belongs_to(:slot, Patchbay.Offers.Slot, allow_nil?: false, public?: true)
    belongs_to(:target_placement, Patchbay.Offers.Placement, allow_nil?: true, public?: true)
    belongs_to(:winner_bid, Patchbay.Offers.Bid, allow_nil?: true, public?: true)

    has_many(:bids, Patchbay.Offers.Bid, destination_attribute: :window_id)
  end

  actions do
    defaults([:read])

    create :open do
      description("Opens a window for the first bid in its slot and lane.")

      accept([
        :slot_id,
        :lane,
        :target_generation,
        :target_next_revision,
        :target_placement_id,
        :baseline_minor,
        :opened_at,
        :closes_at
      ])
    end

    update :close do
      description("Records how a window ended.")
      accept([:state, :winner_bid_id, :settled_at])
    end

    update :settle do
      description("Settles everything due in this window's slot, this window included.")
      require_atomic?(false)
      manual(Patchbay.Offers.Changes.AdvanceSlot)
    end
  end

  policies do
    # Windows are public: anyone may see that a slot is awaiting settlement.
    # They are written only inside the bidding actions and their jobs.
    policy action_type(:read) do
      authorize_if(always())
    end
  end
end
