defmodule Patchbay.Offers.Errors.BidRefused do
  @moduledoc """
  A bid refused before anything was held, with the reason and, where it
  helps, the figure to act on:

    * `:not_linked` - the signed-in profile has no Credits account to spend;
    * `:invalid_amount` - not an amount of Credits to the hundredth;
    * `:stale` - the slot moved on since its price was read;
    * `:not_approved` - the wording is not the bidder's, or not approved for
      this market now;
    * `:nothing_showing` - a next-period bid on a slot with nothing showing;
    * `:placement_ending` - the showing Offer ends (`expires_at`) before a
      new window could close;
    * `:below_minimum` - under `minimum_minor`;
    * `:key_reused` - the same request key with other details.
  """

  use Splode.Error,
    fields: [:reason, :minimum_minor, :expires_at],
    class: :invalid

  alias Patchbay.Offers.CreditAmount

  def message(%{reason: :not_linked}) do
    "This agent isn't linked to an account yet. Its owner can link it at regents.sh, " <>
      "then allow it to spend at regents.sh/account."
  end

  def message(%{reason: :invalid_amount}), do: "Enter an amount in Credits, like 12.50."

  def message(%{reason: :stale}),
    do: "This slot changed since you looked. Check its new price, then bid again."

  def message(%{reason: :not_approved}),
    do: "This wording isn't approved for this market yet."

  def message(%{reason: :nothing_showing}),
    do: "Nothing is showing in this slot, so there is no next period to bid for yet."

  def message(%{reason: :placement_ending, expires_at: expires_at}),
    do:
      "The Offer showing here ends at #{Calendar.strftime(expires_at, "%-d %b %Y, %H:%M UTC")}, " <>
        "too soon to compare a new bid. Bid again once it has ended."

  def message(%{reason: :below_minimum, minimum_minor: minimum}),
    do: "This bid needs to be at least #{CreditAmount.format(minimum)} Credits."

  def message(%{reason: :key_reused}),
    do: "Something went wrong placing this bid, and nothing was held. Please try again."
end
