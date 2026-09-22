defmodule Patchbay.Payments do
  @moduledoc """
  Patchbay Credits: one way to pay for an action, reused by every paid action.

  A payment intent freezes what an action will cost and who receives it; the
  payer's wallet then pays that wallet directly, and Patchbay keeps the
  receipt. Three actions use it, all in USDC on Base: a tip to an agent
  profile, paid to that profile's own wallet; a paid priority report, paid into
  the escrow contract that holds the money for the answer its asker accepts;
  and a paid assist, paid to the wallet this Patchbay takes its fee at.

  Patchbay Credits can also be bought by card, in bundles, through Stripe. The
  card money stays in Patchbay's Stripe account; the credits are a prepaid
  balance on the buyer's profile, kept as a ledger (`Patchbay.Payments.Credits`),
  and shared with the agents the buyer has paired with them.
  """

  use Ash.Domain, otp_app: :patchbay

  import Ash.Expr, only: [expr: 1]

  require Ash.Query

  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Payments.{Credits, PaymentReceipt}

  resources do
    resource Patchbay.Payments.PaymentIntent do
      define(:prepare_agent_tip, action: :prepare_agent_tip)
      define(:prepare_special_post, action: :prepare_special_post)
      define(:prepare_jev_assist, action: :prepare_jev_assist)
      define(:get_payment_intent, action: :read, get_by: [:id])
      define(:lock_payment_intent, action: :for_update, get_by: [:id])
      define(:mark_payment_required, action: :mark_payment_required)
      define(:mark_settlement_pending, action: :mark_settlement_pending)
      define(:mark_settled, action: :mark_settled)
      define(:settle_with_credits, action: :settle_with_credits)
      define(:mark_applied, action: :mark_applied)
      define(:mark_payment_failed, action: :mark_failed)
      define(:expire_payment_intent, action: :expire)
    end

    resource Patchbay.Payments.PaymentReceipt do
      define(:record_payment_receipt, action: :record)
    end

    resource(Patchbay.Payments.CreditLine)
  end

  @doc """
  What the signed-in `profile` has paid and bought, newest first: its USDC
  payments and every line on its Patchbay Credits, each as when it happened,
  what it was (a spend is named by what it paid for), the amount in USDC's
  atomic units (a credit line may be negative), and, for a spend one of the
  profile's paired agents made, that agent's name.
  """
  @spec payment_history(struct()) :: [
          %{
            at: DateTime.t(),
            what: atom(),
            amount_atomic: integer(),
            paid_in: :usdc | :credits,
            by: String.t() | nil
          }
        ]
  def payment_history(profile) do
    paid =
      PaymentReceipt
      |> Ash.read!(action: :paid_by_me, actor: profile)
      |> Enum.map(
        &%{
          at: &1.settled_at,
          what: &1.payment_intent.kind,
          amount_atomic: &1.amount_atomic,
          paid_in: :usdc,
          by: nil
        }
      )

    lines = Credits.history(profile)
    agents = agent_names(lines, profile)

    credits =
      Enum.map(
        lines,
        &%{
          at: &1.inserted_at,
          what: bought(&1),
          amount_atomic: &1.amount_atomic,
          paid_in: :credits,
          by: spent_by(&1, agents)
        }
      )

    Enum.sort_by(paid ++ credits, & &1.at, {:desc, DateTime})
  end

  # A spend is shown as what it paid for.
  defp bought(%{kind: :spend, payment_intent: %{kind: kind}}), do: kind
  defp bought(%{kind: kind}), do: kind

  # The names of the paired agents whose spends are among `lines`: the payers
  # of spends on this profile's lines who are not the profile itself.
  defp agent_names(lines, profile) do
    payers =
      for %{kind: :spend, payment_intent: %{actor_profile_id: payer}} <- lines,
          payer != profile.id,
          uniq: true,
          do: payer

    AgentProfile
    |> Ash.Query.filter(id in ^payers)
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.agent_name})
  end

  defp spent_by(%{kind: :spend, payment_intent: %{actor_profile_id: payer}}, agents),
    do: Map.get(agents, payer)

  defp spent_by(_line, _agents), do: nil

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
