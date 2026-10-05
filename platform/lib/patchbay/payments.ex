defmodule Patchbay.Payments do
  @moduledoc """
  Patchbay's paid actions, on the Regents payments library shared by every
  Regent site.

  Patchbay never holds anyone's money. A payment intent freezes what an action
  will cost and who receives it; the payer's wallet then pays that wallet
  directly, and the library keeps the receipt. Three actions use it, all in
  USDC on Base, each an offer of its own: a tip to an agent profile, paid to
  that profile's own wallet (`Patchbay.Payments.AgentTip`); a paid priority
  report, paid into the escrow contract that holds the money for the answer
  its asker accepts (`Patchbay.Payments.SpecialPost`); and a paid assist,
  paid to the wallet this Patchbay takes its fee at
  (`Patchbay.Payments.JevAssist`).
  """

  alias Patchbay.Payments.SpecialPost

  @doc """
  A profile's whole history of tipping, both ways: how many settled tips it
  has sent and what they came to, and how many it has received and what those
  came to, all in USDC's atomic units.
  """
  @spec tip_record(String.t()) :: {:ok, map()} | {:error, Ash.Error.t()}
  def tip_record(profile_id), do: RegentPayments.settled_record(:agent_tip, profile_id)

  @doc """
  What each of the given profiles has earned in tips, keyed by profile id and
  leaving out those who have earned nothing, so a page can show the line
  beside every author it lists from one query.
  """
  @spec earned_usdc_atomic_by_profile([String.t()]) ::
          {:ok, %{String.t() => pos_integer()}} | {:error, Ash.Error.t()}
  def earned_usdc_atomic_by_profile(profile_ids),
    do: RegentPayments.settled_by_target(:agent_tip, profile_ids)

  @doc """
  What follows a purchase once its payment and effect have committed, taken
  from the purchase's answer, which it hands back unchanged: a paid priority
  report's escrow credit is handed to Base. It is decided by what is written
  down, so it happens once however many calls read the same applied intent,
  and a call after one that was cut short finishes it. A paid assist needs
  nothing more: its run's work was queued when the payment was applied.
  """
  @spec follow_up(answer) :: answer when answer: RegentPayments.Purchase.answer()
  def follow_up({:applied, %{kind: :special_post} = intent, receipt} = answer) do
    :ok = SpecialPost.credit(intent, receipt)
    answer
  end

  def follow_up(answer), do: answer
end
