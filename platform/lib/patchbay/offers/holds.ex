defmodule Patchbay.Offers.Holds do
  @moduledoc """
  The Offers' calls to the shared Credits ledger (`RegentCredits`).

  A bid's Credits are held under the bid's id. When the bid starts showing,
  the same Credits are carried over to the placement's id, and when the
  placement ends they are settled once, in the split the placement records.
  Every call runs inside the caller's transaction, after the slot's lock and
  `lock!/2`, so the money and the slot never disagree. Amounts go to the
  ledger as whole Credits, exactly.
  """

  alias Patchbay.Credits
  alias Patchbay.Offers.CreditAmount

  @purpose "offer_bid"

  @doc """
  Locks, once and in order, the accounts of every owner of `holders` (bids
  and placements whose holds a step may close), of `privy_user_ids`, and
  Regent's revenue.
  """
  def lock!(holders, privy_user_ids) do
    RegentCredits.lock_holds!(Enum.map(holders, & &1.id), privy_user_ids,
      actor: Credits.site_actor()
    )
  end

  @doc "Holds a bid's full amount from the bidder's available Credits."
  def hold(bid, spender) do
    RegentCredits.hold(
      bid.id,
      spender.privy_user_id,
      CreditAmount.to_credits(bid.amount_minor),
      @purpose,
      actor: spender
    )
  end

  @doc "Gives a bid's hold back in full."
  def give_back!(bid, reason),
    do: RegentCredits.give_back!(bid.id, Atom.to_string(reason), actor: Credits.site_actor())

  @doc "Moves a winning bid's hold, untouched, to its placement."
  def carry_over!(bid, placement),
    do: RegentCredits.carry_over!(bid.id, placement.id, @purpose, actor: Credits.site_actor())

  @doc "Settles an ended placement's hold in the split it recorded."
  def settle!(placement, %{returned: returned, consumed: consumed, forfeited: forfeited}) do
    RegentCredits.settle!(
      placement.id,
      CreditAmount.to_credits(returned),
      CreditAmount.to_credits(consumed),
      CreditAmount.to_credits(forfeited),
      actor: Credits.site_actor()
    )
  end
end
