defmodule Patchbay.Payments.Credits do
  @moduledoc """
  Patchbay Credits bought by card: the bundles on sale, a profile's balance,
  the lines Stripe's word writes to it, spending it, and paying out a bounty
  held in it.

  One credit pays for what one USDC pays for. Card money stays in Patchbay's
  Stripe account; what a profile holds here is prepaid credit, never USDC.

  A person and every agent paired with them share one balance, held on the
  person's lines; an agent paired with nobody holds its own. Whatever a
  profile buys, spends or is paid lands on the balance its holder keeps.

  Every change to a balance is made under locks held until the change
  commits: first the lock of the profile acting or being paid, then, when it
  is an agent paired with a person, the person's. Pairing and unpairing take
  the agent's lock first too, so while one of these holds an agent's lock the
  agent's holder cannot change, and a purchase, a reversal, a pairing and
  anything that reads the balance to spend it are taken one at a time.
  """

  require Ash.Query

  alias Patchbay.Payments.{CreditLine, USDC}

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

  @doc "A balance written out, with a minus sign when it is below zero."
  @spec written(integer()) :: String.t()
  def written(atomic) when atomic < 0, do: "-" <> USDC.format(-atomic)
  def written(atomic), do: USDC.format(atomic)

  @doc """
  What a profile can spend, in USDC's atomic units: the sum of its holder's
  lines, added up by the database. It can be below zero once Stripe has taken
  back a card payment whose credits were already spent.
  """
  @spec balance_atomic(Ash.UUID.t()) :: integer()
  def balance_atomic(profile_id), do: profile_id |> holder_of() |> sum_of_lines()

  @doc """
  The signed-in profile's own lines, newest first, each spend with the
  payment intent it paid for, whoever of the balance's sharers made it.
  """
  @spec history(struct()) :: [CreditLine.t()]
  def history(profile) do
    # A paired agent's intent is its own to read, but what it spent was the
    # person's balance, so the person sees what it paid for.
    CreditLine
    |> Ash.read!(action: :history, actor: profile)
    |> Ash.load!(:payment_intent, authorize?: false)
  end

  @doc """
  Spends the balance `actor` shares on `intent`, the actor's own payment
  intent, when it covers it. Called inside the transaction that holds the
  intent's row lock; the balance is read and the spend written under the
  balance's locks, so two spends can never both take the last of it.
  """
  @spec spend(struct(), struct()) ::
          {:ok, CreditLine.t()} | {:short, integer()} | {:error, term()}
  def spend(actor, intent) do
    holder = hold_balance(actor.id)
    balance = sum_of_lines(holder)

    # The actor's own locked intent, checked against the balance it shares.
    if balance >= intent.amount_atomic,
      do:
        record(:record_spend, %{
          profile_id: holder,
          payment_intent_id: intent.id,
          amount_atomic: -intent.amount_atomic
        }),
      else: {:short, balance}
  end

  @doc """
  Pays a bounty held in credits to `profile_id`, the author of the answer its
  asker accepted, onto the balance that author spends now. 90% is paid and
  Patchbay keeps 10%, the split the escrow contract pays a bounty held in
  USDC. Called inside the transaction that holds the report's row lock; a
  report is paid out once, whether awarded or returned.
  """
  @spec award_bounty(struct(), Ash.UUID.t()) :: {:ok, CreditLine.t()} | {:error, term()}
  def award_bounty(report, profile_id),
    do: pay_out(:bounty_award, report, hold_balance(profile_id))

  @doc """
  Pays a bounty held in credits back, 90% of it, to the balance that paid for
  it, whoever the asker has been paired with since. Called like
  `award_bounty/2`.
  """
  @spec return_bounty(struct()) :: {:ok, CreditLine.t()} | {:error, term()}
  def return_bounty(report) do
    # Patchbay's own rule finds who paid; the asker was authorized on the report.
    with {:ok, spend} <-
           CreditLine
           |> Ash.Query.for_read(:spend_for_payment, %{
             payment_intent_id: report.payment_intent_id
           })
           |> Ash.read_one(authorize?: false, not_found_error?: true) do
      pay_out(:bounty_return, report, hold_balance(spend.profile_id))
    end
  end

  # Patchbay's own rule pays the bounty out: the asker's accept or return was
  # authorized on the report, and the profile being paid is not acting.
  defp pay_out(kind, report, holder) do
    record(:record_bounty_payout, %{
      kind: kind,
      profile_id: holder,
      report_id: report.id,
      amount_atomic: bounty_share(report.priority_amount_atomic)
    })
  end

  @doc "What a bounty of `amount_atomic` pays out: 90%, with 10% kept by Patchbay."
  @spec bounty_share(pos_integer()) :: pos_integer()
  def bounty_share(amount_atomic), do: div(amount_atomic * 9, 10)

  @doc """
  Credits `cents` of card payment `stripe_payment_intent_id` to a profile.
  Stripe sends an event again until it is answered, so a payment already
  credited is left as it is.
  """
  @spec record_card_purchase(Ash.UUID.t(), pos_integer(), String.t()) ::
          {:ok, :credited | :already_credited} | {:error, term()}
  def record_card_purchase(profile_id, cents, stripe_payment_intent_id) do
    Ash.transact(CreditLine, fn ->
      profile_id
      |> hold_balance()
      |> credit_once(cents, stripe_payment_intent_id)
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
  not. The payment is a bundle's, so until its purchase is written there is
  nothing to take back yet, and the refund is refused for Stripe to send
  again.
  """
  @spec record_card_refund(String.t(), non_neg_integer()) ::
          {:ok, :reversed | :already_reversed} | {:error, term()}
  def record_card_refund(stripe_payment_intent_id, refunded_cents) do
    take_back(stripe_payment_intent_id, {:error, :purchase_not_written}, fn lines ->
      refunded = Enum.sum(for line <- lines, reversal_for_refund?(line), do: -line.amount_atomic)
      {atomic_from_cents(refunded_cents) - refunded, nil}
    end)
  end

  @doc """
  Takes back `cents` of card payment `stripe_payment_intent_id` for dispute
  `stripe_dispute_id`, once for each dispute. A dispute does not say whether
  its payment was a bundle, so one for a payment Patchbay never credited is
  not Patchbay's to answer for.
  """
  @spec record_card_dispute(String.t(), String.t(), pos_integer()) ::
          {:ok, :reversed | :already_reversed | :not_ours} | {:error, term()}
  def record_card_dispute(stripe_payment_intent_id, stripe_dispute_id, cents) do
    take_back(stripe_payment_intent_id, {:ok, :not_ours}, fn lines ->
      if Enum.any?(lines, &(&1.stripe_dispute_id == stripe_dispute_id)),
        do: {0, stripe_dispute_id},
        else: {atomic_from_cents(cents), stripe_dispute_id}
    end)
  end

  # Never more is taken back from a card payment, in all, than it bought.
  defp take_back(stripe_payment_intent_id, nothing_bought, owed) do
    case lines_for(stripe_payment_intent_id) do
      [] ->
        nothing_bought

      # Taken back from whoever holds the balance the purchase went to now.
      [%{profile_id: profile_id} | _lines] ->
        Ash.transact(CreditLine, fn ->
          profile_id
          |> hold_balance()
          |> reverse(stripe_payment_intent_id, owed)
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

  # Same: Stripe's signed word, a payer's own locked intent, Patchbay's own
  # bounty rule or a pairing writes the line.
  defp record(action, attributes) do
    CreditLine
    |> Ash.Changeset.for_create(action, attributes)
    |> Ash.create(authorize?: false)
  end

  @doc """
  Takes the locks for pairing agent `agent_id` with person `person_id`:
  the agent's first, as for anything the agent does, then the person it is
  paired with now and the person it is pairing with, in one fixed order so
  two pairings never wait on each other.
  """
  @spec hold_for_pairing(Ash.UUID.t(), Ash.UUID.t()) :: :ok
  def hold_for_pairing(agent_id, person_id) do
    hold(agent_id)

    [holder_of(agent_id), person_id]
    |> Enum.reject(&(&1 == agent_id))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&hold/1)
  end

  @doc """
  Moves what agent `agent_id` holds on its own lines onto person
  `person_id`, whatever its sign, as it pairs with them. Called under
  `hold_for_pairing/2`'s locks; an agent holding nothing moves nothing.
  """
  @spec move_to_person(Ash.UUID.t(), Ash.UUID.t()) :: :ok | {:error, term()}
  def move_to_person(agent_id, person_id) do
    case sum_of_lines(agent_id) do
      0 ->
        :ok

      held ->
        with {:ok, _out} <-
               record(:record_pairing_move, %{profile_id: agent_id, amount_atomic: -held}),
             {:ok, _in} <-
               record(:record_pairing_move, %{profile_id: person_id, amount_atomic: held}),
             do: :ok
    end
  end

  # The profile whose lines hold `profile_id`'s balance: the person an agent
  # is paired with, or the profile itself.
  defp holder_of(profile_id) do
    case Patchbay.Identity.get_profile!(profile_id) do
      %{paired_person_id: nil} -> profile_id
      %{paired_person_id: person_id} -> person_id
    end
  end

  # The profile's own lock first, which pins who holds its balance, then the
  # holder's; answers the holder.
  defp hold_balance(profile_id) do
    hold(profile_id)
    holder = holder_of(profile_id)
    if holder != profile_id, do: hold(holder)
    holder
  end

  # Patchbay's own sum, read under the balance's locks before anything is
  # spent from it, and shown only to the person it belongs to.
  defp sum_of_lines(profile_id) do
    CreditLine
    |> Ash.Query.filter(profile_id == ^profile_id)
    |> Ash.sum!(:amount_atomic, authorize?: false)
    |> Kernel.||(0)
  end

  defp hold(profile_id) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "patchbay credits " <> profile_id
    ])
  end
end
