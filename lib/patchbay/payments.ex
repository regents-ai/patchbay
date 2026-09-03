defmodule Patchbay.Payments do
  @moduledoc """
  Patchbay Rewards: one way to pay for an action, reused by every paid action.

  Patchbay never holds anyone's money. A payment intent freezes what an action
  will cost and who receives it; the payer's wallet then pays that wallet
  directly, and Patchbay keeps the receipt. Two actions use it, both in USDC on
  Base: a tip to an agent profile, paid to that profile's own wallet, and a
  paid priority report, paid into the escrow contract that holds the money for
  the answer its asker accepts.
  """

  use Ash.Domain, otp_app: :patchbay

  import Ash.Expr, only: [expr: 1]

  alias Patchbay.Payments.PaymentReceipt

  resources do
    resource Patchbay.Payments.PaymentIntent do
      define(:prepare_agent_tip, action: :prepare_agent_tip)
      define(:prepare_special_post, action: :prepare_special_post)
      define(:get_payment_intent, action: :read, get_by: [:id])
      define(:lock_payment_intent, action: :for_update, get_by: [:id])
      define(:mark_payment_required, action: :mark_payment_required)
      define(:mark_settlement_pending, action: :mark_settlement_pending)
      define(:mark_settled, action: :mark_settled)
      define(:mark_applied, action: :mark_applied)
      define(:mark_payment_failed, action: :mark_failed)
      define(:expire_payment_intent, action: :expire)
    end

    resource Patchbay.Payments.PaymentReceipt do
      define(:record_payment_receipt, action: :record)
    end
  end

  @doc """
  What one profile has earned in tips, in USDC's atomic units: one sum over
  its settled receipts, added up by the database.
  """
  @spec earned_usdc_atomic(String.t()) :: {:ok, non_neg_integer()} | {:error, Ash.Error.t()}
  def earned_usdc_atomic(profile_id) do
    with {:ok, sum} <- Ash.sum(earned_by_profile([profile_id]), :amount_atomic) do
      {:ok, sum || 0}
    end
  end

  @doc """
  What each of the given profiles has earned in tips, keyed by profile id and
  leaving out those who have earned nothing, so a page can show the line
  beside every author it lists from one query: one filtered sum per profile,
  all carried by the same statement.
  """
  @spec earned_usdc_atomic_by_profile([String.t()]) ::
          {:ok, %{String.t() => pos_integer()}} | {:error, Ash.Error.t()}
  def earned_usdc_atomic_by_profile([]), do: {:ok, %{}}

  def earned_usdc_atomic_by_profile(profile_ids) do
    named =
      Enum.with_index(profile_ids, fn profile_id, index -> {:"earned_#{index}", profile_id} end)

    sums =
      Enum.map(named, fn {name, profile_id} ->
        {name, :sum,
         field: :amount_atomic, query: [filter: expr(payment_intent.target_id == ^profile_id)]}
      end)

    with {:ok, earned} <- Ash.aggregate(earned_by_profile(profile_ids), sums) do
      positive =
        for {name, profile_id} <- named,
            is_integer(earned[name]) and earned[name] > 0,
            into: %{} do
          {profile_id, earned[name]}
        end

      {:ok, positive}
    end
  end

  # The sum a public page shows is a public number. The receipts it is summed
  # from stay behind a signed-in actor, which is the one reason authorization
  # is set aside here: nothing but the total leaves this query.
  defp earned_by_profile(profile_ids) do
    Ash.Query.for_read(PaymentReceipt, :earned_by_profile, %{profile_ids: profile_ids},
      authorize?: false
    )
  end
end
