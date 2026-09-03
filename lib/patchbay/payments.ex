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
  A profile's whole history of tipping, both ways: how many settled tips it has
  sent and what they came to, and how many it has received and what those came
  to, all in USDC's atomic units.

  A tip is one wallet paying another directly, so nothing on the chain says
  which Patchbay profile sent it. The intent behind each settled receipt does:
  it names the paying profile and the profile paid at the moment the terms were
  frozen. Counting the receipts is therefore counting the tips.

  Four filtered aggregates, all carried by one statement.
  """
  @spec tip_record(String.t()) :: {:ok, map()} | {:error, Ash.Error.t()}
  def tip_record(profile_id) do
    aggregates = [
      {:given_count, :count,
       query: [filter: expr(payment_intent.actor_profile_id == ^profile_id)]},
      {:given_atomic, :sum,
       field: :amount_atomic,
       query: [filter: expr(payment_intent.actor_profile_id == ^profile_id)]},
      {:received_count, :count, query: [filter: expr(payment_intent.target_id == ^profile_id)]},
      {:received_atomic, :sum,
       field: :amount_atomic, query: [filter: expr(payment_intent.target_id == ^profile_id)]}
    ]

    with {:ok, counted} <- Ash.aggregate(tips_for_profile(profile_id), aggregates) do
      {:ok,
       %{
         given_count: counted.given_count || 0,
         given_atomic: counted.given_atomic || 0,
         received_count: counted.received_count || 0,
         received_atomic: counted.received_atomic || 0
       }}
    end
  end

  # The four numbers a public page shows are public numbers. The receipts they
  # are counted from stay behind a signed-in actor, which is the one reason
  # authorization is set aside here: nothing but the totals leaves this query.
  defp tips_for_profile(profile_id) do
    Ash.Query.for_read(PaymentReceipt, :tips_for_profile, %{profile_id: profile_id},
      authorize?: false
    )
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
