defmodule Patchbay.Offers.Advance do
  @moduledoc """
  Brings one slot up to date, under its lock, before anything else happens
  to it.

  Every bid, every removal and every job starts here: lock the slot, then
  every Credits account the step may move (`Patchbay.Offers.Holds.lock!/2`),
  take the database's clock once, then

    1. if the showing placement has reached its expiry, end it (all of it
       used), give back every bid in the slot's open windows, and start the
       waiting next-period leader if it can start;
    2. otherwise settle the slot's due windows one at a time, by closing
       time, the immediate lane before the next-period lane at a tie.

  Each step moves its Credits (`Patchbay.Offers.Holds`) in the same
  transaction, so the slot and the ledger never disagree.
  """

  require Ash.Query

  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.BidWindow
  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.Holds
  alias Patchbay.Offers.Placement
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms
  alias Patchbay.Repo

  @loads [:market, :active_placement, :next_bid]

  @doc """
  Locks a slot's row for the rest of the transaction and reads it, or nil.
  Then locks, together, the Credits accounts of everyone whose hold the step
  may close and of `privy_user_ids` (a bidder about to be held for), so two
  slots settling at once never take the same people in opposite orders.
  """
  def lock(slot_id, privy_user_ids) do
    # Part of the action that asked, whose policy already decided.
    slot =
      Slot
      |> Ash.Query.filter(id == ^slot_id)
      |> Ash.Query.lock(:for_update)
      |> Ash.Query.load(@loads)
      |> Ash.read_one!(authorize?: false)

    if slot, do: Holds.lock!(holders(slot), privy_user_ids)
    slot
  end

  # Every hold a step may close: the showing placement's, the waiting
  # leader's, and each bid still held in one of the slot's windows. A
  # placement a step starts carries over one of these bids' holds.
  defp holders(slot) do
    # Part of the action that asked, whose policy already decided.
    held =
      Bid
      |> Ash.Query.filter(slot_id == ^slot.id and status == :held)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)

    Enum.reject([slot.active_placement, slot.next_bid], &is_nil/1) ++ held
  end

  @doc "The database's clock now, read after the locks are held."
  def now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  @doc "Ends what has expired and settles what is due in a locked slot."
  def advance(slot, now) do
    case slot.active_placement do
      %Placement{expires_at: expires_at} = placement ->
        if DateTime.after?(expires_at, now),
          do: settle_due(slot, now),
          else: expire(slot, placement, now)

      nil ->
        settle_due(slot, now)
    end
  end

  defp expire(slot, placement, now) do
    finish(placement, :expired, placement.expires_at, Terms.expired(placement.amount_minor))
    give_back_windows(slot, [:immediate, :next_period], :stale, now)
    promote(slot, now)
  end

  @doc """
  Ends a placement as `status` at `ended_at` and settles its hold in `split`.
  """
  def finish(placement, status, ended_at, split) do
    # Part of the action that asked, whose policy already decided.
    placement
    |> Ash.Changeset.for_update(:finish, %{
      status: status,
      ended_at: ended_at,
      returned_minor: split.returned,
      consumed_minor: split.consumed,
      forfeited_minor: split.forfeited
    })
    |> Ash.update!(authorize?: false)

    Holds.settle!(placement, split)
  end

  @doc """
  Closes the slot's open windows in `lanes` without a winner, giving back
  every bid in them in full for `reason`.
  """
  def give_back_windows(slot, lanes, reason, now) do
    # Part of the action that asked, whose policy already decided.
    BidWindow
    |> Ash.Query.filter(slot_id == ^slot.id and state == :open and lane in ^lanes)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn window ->
      window |> held_bids() |> Enum.each(&give_back(&1, reason, now))
      close(window, :stale, nil, now)
    end)
  end

  @doc """
  Starts the slot's waiting next-period leader at `now` if its wording may
  still show here, or gives it back; either way the slot's active owner
  changes.
  """
  def promote(%Slot{next_bid: nil} = slot, _now),
    do: point(slot, %{active_placement_id: nil, active_generation: slot.active_generation + 1})

  def promote(%Slot{next_bid: leader} = slot, now) do
    active_placement_id =
      if leader.version_id in eligible_versions(slot.market, [leader.version_id], now) do
        start(slot, leader, now).id
      else
        give_back(leader, :ineligible, now)
        nil
      end

    point(slot, %{
      active_placement_id: active_placement_id,
      next_bid_id: nil,
      active_generation: slot.active_generation + 1,
      next_revision: slot.next_revision + 1
    })
  end

  defp settle_due(slot, now) do
    # Part of the action that asked, whose policy already decided.
    BidWindow
    |> Ash.Query.filter(slot_id == ^slot.id and state == :open and closes_at <= ^now)
    |> Ash.Query.sort(closes_at: :asc, lane: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> slot
      window -> slot |> settle_window(window, now) |> settle_due(now)
    end
  end

  # A window whose slot has moved on gives every bid back. Otherwise the
  # highest bid whose wording may show wins, ties to the earliest; a higher
  # bid whose wording may not show is given back as ineligible, never let
  # through to a runner-up it would have beaten.
  defp settle_window(slot, window, now) do
    if current?(slot, window) do
      bids = held_bids(window)
      eligible = eligible_versions(slot.market, Enum.map(bids, & &1.version_id), now)
      {ineligible, rest} = Enum.split_while(bids, &(&1.version_id not in eligible))
      Enum.each(ineligible, &give_back(&1, :ineligible, now))
      decide(slot, window, rest, now)
    else
      window |> held_bids() |> Enum.each(&give_back(&1, :stale, now))
      close(window, :stale, nil, now)
      slot
    end
  end

  defp current?(slot, %BidWindow{lane: :immediate} = window),
    do: window.target_generation == slot.active_generation

  defp current?(slot, %BidWindow{lane: :next_period} = window),
    do:
      window.target_generation == slot.active_generation and
        window.target_next_revision == slot.next_revision

  defp decide(slot, window, [], now) do
    close(window, :unfilled, nil, now)
    slot
  end

  defp decide(slot, window, [winner | outbid], now) do
    Enum.each(outbid, &give_back(&1, :outbid, now))
    close(window, :won, winner.id, now)
    win(slot, winner, now)
  end

  # Buying out: the showing placement ends with its unused share returned,
  # the waiting leader and every next-period bid made against it come back
  # in full, and the winner starts a fresh term at once.
  defp win(slot, %Bid{lane: :immediate} = winner, now) do
    if placement = slot.active_placement do
      finish(
        placement,
        :bought_out,
        now,
        Terms.bought_out(placement.amount_minor, placement.expires_at, now)
      )
    end

    if leader = slot.next_bid, do: give_back(leader, :cancelled_by_buyout, now)
    give_back_windows(slot, [:next_period], :cancelled_by_buyout, now)

    point(slot, %{
      active_placement_id: start(slot, winner, now).id,
      next_bid_id: nil,
      active_generation: slot.active_generation + 1,
      next_revision: slot.next_revision + if(slot.next_bid, do: 1, else: 0)
    })
  end

  # A new next-period leader: its hold stays where it is, under the bid.
  defp win(slot, %Bid{lane: :next_period} = winner, now) do
    if leader = slot.next_bid, do: give_back(leader, :next_leader_replaced, now)
    resolve(winner, %{status: :leading})
    point(slot, %{next_bid_id: winner.id, next_revision: slot.next_revision + 1})
  end

  defp start(slot, bid, now) do
    # Part of the action that asked, whose policy already decided.
    placement =
      Placement
      |> Ash.Changeset.for_create(:start, %{
        owner_profile_id: bid.owner_profile_id,
        version_id: bid.version_id,
        slot_id: slot.id,
        bid_id: bid.id,
        amount_minor: bid.amount_minor,
        minimum_minor: bid.minimum_minor,
        policy_revision: bid.policy_revision,
        duration_us: bid.duration_us,
        generation: slot.active_generation + 1,
        starts_at: now,
        expires_at: DateTime.add(now, bid.duration_us, :microsecond)
      })
      |> Ash.create!(authorize?: false)

    Holds.carry_over!(bid, placement)
    resolve(bid, %{status: :placed, resolved_at: now})
    AshOban.run_trigger(placement, :expire, scheduled_at: placement.expires_at)
    placement
  end

  defp give_back(bid, reason, now) do
    resolve(bid, %{status: :returned, return_reason: reason, resolved_at: now})
    Holds.give_back!(bid, reason)
  end

  defp resolve(bid, changes) do
    # Part of the action that asked, whose policy already decided.
    bid
    |> Ash.Changeset.for_update(:resolve, changes)
    |> Ash.update!(authorize?: false)
  end

  defp held_bids(window) do
    # Part of the action that asked, whose policy already decided.
    Bid
    |> Ash.Query.filter(window_id == ^window.id and status == :held)
    |> Ash.Query.sort(amount_minor: :desc, sequence: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp close(window, state, winner_bid_id, now) do
    # Part of the action that asked, whose policy already decided.
    window
    |> Ash.Changeset.for_update(:close, %{
      state: state,
      winner_bid_id: winner_bid_id,
      settled_at: now
    })
    |> Ash.update!(authorize?: false)
  end

  # The slot's own row is already locked; it is read again with what it
  # now points at.
  defp point(slot, changes) do
    slot
    |> Ash.Changeset.for_update(:point, changes)
    |> Ash.update!(authorize?: false)

    Slot
    |> Ash.Query.filter(id == ^slot.id)
    |> Ash.Query.load(@loads)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "Which of `version_ids` may start or show in `market` at `at`."
  def eligible_versions(market, version_ids, at) do
    # Part of the action that asked, whose policy already decided.
    CreativeVersion
    |> Ash.Query.for_read(:eligible, %{
      market_id: market.id,
      global: market.scope == :global,
      at: at
    })
    |> Ash.Query.filter(id in ^version_ids)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end
end
