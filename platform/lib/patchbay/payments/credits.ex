defmodule Patchbay.Payments.Credits do
  @moduledoc """
  Patchbay Credits bought by card: the bundles on sale, a profile's balance,
  and the lines Stripe's word writes to it.

  One credit pays for what one USDC pays for. Card money stays in Patchbay's
  Stripe account; what a profile holds here is prepaid credit, never USDC.

  Every change to one profile's balance is made under that profile's own lock,
  held until the change commits, so a purchase, a reversal and anything that
  reads the balance to spend it are taken one at a time.
  """

  require Ash.Query

  alias Patchbay.Payments.CreditLine

  @bundles_dollars [2, 5, 10, 20, 50]

  # A cent is 10_000 of USDC's atomic units.
  @atomic_per_cent 10_000

  @doc "The bundles on sale, in whole US dollars."
  @spec bundles() :: [pos_integer()]
  def bundles, do: @bundles_dollars

  @doc "Whether `dollars` is one of the bundles on sale."
  @spec bundle?(term()) :: boolean()
  def bundle?(dollars), do: dollars in @bundles_dollars

  @doc "A card amount in US cents, in USDC's atomic units."
  @spec atomic_from_cents(integer()) :: integer()
  def atomic_from_cents(cents), do: cents * @atomic_per_cent

  @doc """
  What a profile holds, in USDC's atomic units: the sum of its lines, added up
  by the database. It can be below zero once Stripe has taken back a card
  payment whose credits were already spent.
  """
  @spec balance_atomic(Ash.UUID.t()) :: integer()
  def balance_atomic(profile_id) do
    # Patchbay's own sum, shown only to the profile it belongs to and read
    # before anything is spent from it.
    CreditLine
    |> Ash.Query.filter(profile_id == ^profile_id)
    |> Ash.sum!(:amount_atomic, authorize?: false)
    |> Kernel.||(0)
  end

  @doc "The signed-in profile's own lines, newest first."
  @spec history(struct()) :: [CreditLine.t()]
  def history(profile) do
    Ash.read!(CreditLine, action: :history, actor: profile)
  end

  @doc """
  Credits `cents` of card payment `stripe_payment_intent_id` to a profile.
  Stripe sends an event again until it is answered, so a payment already
  credited is left as it is.
  """
  @spec record_card_purchase(Ash.UUID.t(), pos_integer(), String.t()) ::
          {:ok, :credited | :already_credited} | {:error, term()}
  def record_card_purchase(profile_id, cents, stripe_payment_intent_id) do
    Ash.transact(CreditLine, fn ->
      hold(profile_id)
      credit_once(profile_id, cents, stripe_payment_intent_id)
    end)
  end

  defp credit_once(profile_id, cents, stripe_payment_intent_id) do
    with [] <- lines_for(stripe_payment_intent_id),
         {:ok, _line} <-
           record(:record_card_purchase, %{
             profile_id: profile_id,
             amount_atomic: atomic_from_cents(cents),
             stripe_payment_intent_id: stripe_payment_intent_id
           }) do
      :credited
    else
      [_credited | _lines] -> :already_credited
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Takes back what Stripe has refunded of card payment
  `stripe_payment_intent_id`. `refunded_cents` is Stripe's running total for
  the payment, so each refund event takes back only what earlier ones did
  not. A payment Patchbay never credited is not Patchbay's to answer for.
  """
  @spec record_card_refund(String.t(), non_neg_integer()) ::
          {:ok, :reversed | :already_reversed | :not_ours} | {:error, term()}
  def record_card_refund(stripe_payment_intent_id, refunded_cents) do
    take_back(stripe_payment_intent_id, fn lines ->
      refunded = Enum.sum(for line <- lines, reversal_for_refund?(line), do: -line.amount_atomic)
      {atomic_from_cents(refunded_cents) - refunded, nil}
    end)
  end

  @doc """
  Takes back `cents` of card payment `stripe_payment_intent_id` for dispute
  `stripe_dispute_id`, once for each dispute.
  """
  @spec record_card_dispute(String.t(), String.t(), pos_integer()) ::
          {:ok, :reversed | :already_reversed | :not_ours} | {:error, term()}
  def record_card_dispute(stripe_payment_intent_id, stripe_dispute_id, cents) do
    take_back(stripe_payment_intent_id, fn lines ->
      if Enum.any?(lines, &(&1.stripe_dispute_id == stripe_dispute_id)),
        do: {0, stripe_dispute_id},
        else: {atomic_from_cents(cents), stripe_dispute_id}
    end)
  end

  # Never more is taken back from a card payment, in all, than it bought.
  defp take_back(stripe_payment_intent_id, owed) do
    case lines_for(stripe_payment_intent_id) do
      [] ->
        {:ok, :not_ours}

      [%{profile_id: profile_id} | _lines] ->
        Ash.transact(CreditLine, fn ->
          hold(profile_id)
          reverse(profile_id, stripe_payment_intent_id, owed)
        end)
    end
  end

  defp reverse(profile_id, stripe_payment_intent_id, owed) do
    lines = lines_for(stripe_payment_intent_id)
    {amount, dispute_id} = owed.(lines)
    amount = min(amount, Enum.sum_by(lines, & &1.amount_atomic))

    with true <- amount > 0,
         {:ok, _line} <-
           record(:record_card_reversal, %{
             profile_id: profile_id,
             amount_atomic: -amount,
             stripe_payment_intent_id: stripe_payment_intent_id,
             stripe_dispute_id: dispute_id
           }) do
      :reversed
    else
      false -> :already_reversed
      {:error, error} -> {:error, error}
    end
  end

  defp reversal_for_refund?(line),
    do: line.kind == :card_reversal and is_nil(line.stripe_dispute_id)

  # Stripe's signed word is what writes these lines, with no person acting.
  defp lines_for(stripe_payment_intent_id) do
    CreditLine
    |> Ash.Query.for_read(:for_card_payment, %{stripe_payment_intent_id: stripe_payment_intent_id})
    |> Ash.read!(authorize?: false)
  end

  # Same: Stripe's signed word writes the line, for no person acting.
  defp record(action, attributes) do
    CreditLine
    |> Ash.Changeset.for_create(action, attributes)
    |> Ash.create(authorize?: false)
  end

  defp hold(profile_id) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "patchbay credits " <> profile_id
    ])
  end
end
