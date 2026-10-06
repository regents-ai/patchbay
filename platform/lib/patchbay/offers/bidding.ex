defmodule Patchbay.Offers.Bidding do
  @moduledoc """
  The work behind `Patchbay.Offers.Bid`'s `:submit`, inside its transaction.

  It locks the slot and brings it up to date first (`Patchbay.Offers.Advance`),
  so a late job never lets a bid skip past an expiry or a due window. Then:
  the same request key answers with its bid; the slot must still be as the
  bidder saw it; the wording must be theirs and approved for this market;
  the bid joins the lane's open window or opens one closing two seconds
  later; it must meet the window's minimum; and its full amount is held
  from the bidder's Credits. Any refusal rolls everything back, so nothing
  is held for a bid that was not taken. A bidder short of Credits is refused
  by the ledger itself (`RegentCredits.Errors.NotEnoughCredits`, with the
  shortfall).
  """

  require Ash.Query

  alias Patchbay.Credits
  alias Patchbay.Offers
  alias Patchbay.Offers.Advance
  alias Patchbay.Offers.Bid
  alias Patchbay.Offers.BidWindow
  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.CreditAmount
  alias Patchbay.Offers.Errors.BidRefused
  alias Patchbay.Offers.Holds
  alias Patchbay.Offers.Slot
  alias Patchbay.Offers.Terms

  @window_us 2_000_000

  @doc "Places one bid for `profile`, or refuses it with nothing held."
  def submit(args, profile) do
    with {:ok, spender} <- spender(profile),
         {:ok, amount_minor} <- amount(args.amount),
         %Slot{} = slot <- Advance.lock(args.slot_id) || {:error, not_found()} do
      now = Advance.now()
      slot = Advance.advance(slot, now)
      request = request_sha256(args, amount_minor)

      case earlier(profile, args.idempotency_key) do
        nil ->
          place(
            slot,
            Map.merge(args, %{amount_minor: amount_minor, request: request}),
            profile,
            spender,
            now
          )

        %Bid{request_sha256: ^request} = bid ->
          {:ok, bid}

        %Bid{} ->
          refuse(:key_reused)
      end
    end
  end

  defp place(slot, args, profile, spender, now) do
    with :ok <- current(slot, args),
         :ok <- approved(slot.market, args.version_id, profile, now),
         {:ok, window} <- window(slot, args.lane, now),
         {:ok, minimum} <- minimum(window, slot.market, args.amount_minor),
         bid = accept(slot, window, args, profile, minimum, now),
         {:ok, _hold} <- Holds.hold(bid, spender) do
      {:ok, bid}
    end
  end

  defp spender(profile) do
    case Credits.spender(profile) do
      {:ok, spender} -> {:ok, spender}
      :not_linked -> refuse(:not_linked)
    end
  end

  defp amount(text) do
    case CreditAmount.parse(text) do
      {:ok, minor} when minor > 0 -> {:ok, minor}
      _other -> refuse(:invalid_amount)
    end
  end

  defp earlier(profile, key) do
    # Part of the action that asked, whose policy already decided.
    Bid
    |> Ash.Query.filter(owner_profile_id == ^profile.id and idempotency_key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp request_sha256(args, amount_minor) do
    [args.slot_id, args.lane, amount_minor, args.version_id]
    |> Enum.concat([args.target_generation, args.target_next_revision])
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # An immediate bid names the active owner it was priced against; a
  # next-period bid also names the waiting leader.
  defp current(slot, %{lane: :immediate} = args),
    do: same(slot.active_generation == args.target_generation)

  defp current(slot, %{lane: :next_period} = args) do
    same(
      slot.active_generation == args.target_generation and
        slot.next_revision == args.target_next_revision
    )
  end

  defp same(true), do: :ok
  defp same(false), do: refuse(:stale)

  defp approved(market, version_id, profile, now) do
    # Part of the action that asked, whose policy already decided.
    owned =
      CreativeVersion
      |> Ash.Query.filter(id == ^version_id and creative.owner_profile_id == ^profile.id)
      |> Ash.exists?(authorize?: false)

    if owned and version_id in Advance.eligible_versions(market, [version_id], now),
      do: :ok,
      else: refuse(:not_approved)
  end

  # Joins the lane's open window, or opens one against the slot's committed
  # baseline. A window that would still be open when the showing Offer
  # expires is never opened.
  defp window(slot, lane, now) do
    BidWindow
    |> Ash.Query.filter(slot_id == ^slot.id and lane == ^lane and state == :open)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %BidWindow{} = window -> {:ok, window}
      nil -> open(slot, lane, now)
    end
  end

  defp open(slot, lane, now) do
    # Part of the action that asked, whose policy already decided.
    closes_at = DateTime.add(now, @window_us, :microsecond)

    with {:ok, baseline} <- baseline(slot, lane),
         :ok <- before_expiry(slot.active_placement, closes_at) do
      window =
        BidWindow
        |> Ash.Changeset.for_create(:open, %{
          slot_id: slot.id,
          lane: lane,
          target_generation: slot.active_generation,
          target_next_revision: slot.next_revision,
          target_placement_id: slot.active_placement_id,
          baseline_minor: baseline,
          opened_at: now,
          closes_at: closes_at
        })
        |> Ash.create!(authorize?: false)

      AshOban.run_trigger(window, :settle, scheduled_at: closes_at)
      {:ok, window}
    end
  end

  defp baseline(%Slot{active_placement: placement}, :immediate),
    do: {:ok, placement && placement.amount_minor}

  defp baseline(%Slot{active_placement: nil}, :next_period), do: refuse(:nothing_showing)
  defp baseline(%Slot{next_bid: leader}, :next_period), do: {:ok, leader && leader.amount_minor}

  defp before_expiry(nil, _closes_at), do: :ok

  defp before_expiry(placement, closes_at) do
    if DateTime.before?(closes_at, placement.expires_at),
      do: :ok,
      else:
        {:error,
         BidRefused.exception(reason: :placement_ending, expires_at: placement.expires_at)}
  end

  defp minimum(window, market, amount_minor) do
    opening = Offers.opening_minimum_minor(market)

    minimum =
      if window.baseline_minor,
        do: Terms.replacement_minimum(window.baseline_minor, opening),
        else: opening

    if amount_minor >= minimum,
      do: {:ok, minimum},
      else: {:error, BidRefused.exception(reason: :below_minimum, minimum_minor: minimum)}
  end

  defp accept(slot, window, args, profile, minimum, now) do
    # Part of the action that asked, whose policy already decided.
    Bid
    |> Ash.Changeset.for_create(:accept, %{
      owner_profile_id: profile.id,
      version_id: args.version_id,
      slot_id: slot.id,
      window_id: window.id,
      target_placement_id: window.target_placement_id,
      lane: args.lane,
      amount_minor: args.amount_minor,
      minimum_minor: minimum,
      opening_minimum_minor: Offers.opening_minimum_minor(slot.market),
      policy_revision: slot.market.policy_revision,
      duration_us: Terms.duration_us(),
      target_generation: args.target_generation,
      target_next_revision: args.target_next_revision,
      idempotency_key: args.idempotency_key,
      request_sha256: args.request,
      accepted_at: now
    })
    |> Ash.create!(authorize?: false)
  end

  defp refuse(reason), do: {:error, BidRefused.exception(reason: reason)}

  defp not_found, do: Ash.Error.Query.NotFound.exception(resource: Slot)
end
