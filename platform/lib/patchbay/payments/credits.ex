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
  Records what Stripe has refunded of card payment
  `stripe_payment_intent_id` and takes those credits back. `refunded_cents`
  is Stripe's running total for the payment, so each refund event records
  only what earlier ones did not. The payment is a bundle's, so until its
  purchase is written there is nothing to take back yet, and the refund is
  refused for Stripe to send again.
  """
  @spec record_card_refund(String.t(), non_neg_integer()) ::
          {:ok, :reversed | :already_reversed} | {:error, term()}
  def record_card_refund(stripe_payment_intent_id, refunded_cents) do
    settle(stripe_payment_intent_id, {:error, :purchase_not_written}, fn lines ->
      case atomic_from_cents(refunded_cents) - refunded(lines) do
        new when new > 0 -> {:take, nil, new}
        _recorded -> :already_reversed
      end
    end)
  end

  @doc """
  Records dispute `stripe_dispute_id` of `cents` on card payment
  `stripe_payment_intent_id` and takes those credits back, once for each
  dispute. A dispute does not say whether its payment was a bundle, so one
  for a payment Patchbay never credited is not Patchbay's to answer for.
  """
  @spec record_card_dispute(String.t(), String.t(), pos_integer()) ::
          {:ok, :reversed | :already_reversed | :not_ours} | {:error, term()}
  def record_card_dispute(stripe_payment_intent_id, stripe_dispute_id, cents) do
    settle(stripe_payment_intent_id, {:ok, :not_ours}, fn lines ->
      if dispute_reversal(lines, stripe_dispute_id),
        do: :already_reversed,
        else: {:take, stripe_dispute_id, atomic_from_cents(cents)}
    end)
  end

  @doc """
  Gives back, once, what dispute `stripe_dispute_id` of card payment
  `stripe_payment_intent_id` took, when Stripe closes it without the money
  leaving: a dispute won, or an inquiry closed. Only what no refund of the
  same payment has taken since is given back, to the balance it was taken
  from, whoever that balance's agents are paired with since; nothing else
  on that balance is touched. A dispute on a payment Patchbay never credited
  is not Patchbay's to answer for; one whose opening is not written yet is
  refused for Stripe to send again.
  """
  @spec record_dispute_won(String.t(), String.t()) ::
          {:ok, :restored | :already_restored | :not_ours} | {:error, term()}
  def record_dispute_won(stripe_payment_intent_id, stripe_dispute_id) do
    settle(stripe_payment_intent_id, {:ok, :not_ours}, fn lines ->
      cond do
        is_nil(dispute_reversal(lines, stripe_dispute_id)) -> :dispute_not_written
        dispute_closed?(lines, stripe_dispute_id) -> :already_restored
        true -> {:give_back, dispute_reversal(lines, stripe_dispute_id)}
      end
    end)
  end

  # Every Stripe event about one card payment is weighed under that
  # payment's own lock, against its lines read under it, so events arriving
  # together or in any order are counted one after another.
  defp settle(stripe_payment_intent_id, nothing_bought, decide) do
    CreditLine
    |> Ash.transact(fn ->
      hold("card payment " <> stripe_payment_intent_id)

      case lines_for(stripe_payment_intent_id) do
        [] -> :nothing_bought
        lines -> lines |> decide.() |> write(stripe_payment_intent_id, lines)
      end
    end)
    |> case do
      {:ok, :nothing_bought} -> nothing_bought
      {:ok, :dispute_not_written} -> {:error, :dispute_not_written}
      settled -> settled
    end
  end

  # What Stripe's events took from the payment decides what is taken back:
  # every refund and every dispute still open, never more than the payment
  # bought. Each line takes back the difference that event makes, so a
  # refund of money a dispute already took back takes nothing more, and a
  # dispute closed later gives back only what the refund does not cover.
  defp write({:take, stripe_dispute_id, stripe_amount}, stripe_payment_intent_id, lines) do
    purchase = Enum.find(lines, &(&1.kind == :card_purchase))
    owed = min(bought(lines), claimed(lines) + stripe_amount) - taken(lines)

    record(:record_card_reversal, %{
      profile_id: hold_balance(purchase.profile_id),
      amount_atomic: -owed,
      stripe_amount_atomic: stripe_amount,
      stripe_payment_intent_id: stripe_payment_intent_id,
      stripe_dispute_id: stripe_dispute_id
    })
    |> written(:reversed)
  end

  defp write({:give_back, reversal}, stripe_payment_intent_id, lines) do
    still_owed = min(bought(lines), claimed(lines) - reversal.stripe_amount_atomic)

    record(:record_dispute_restore, %{
      profile_id: hold_balance(reversal.profile_id),
      amount_atomic: taken(lines) - still_owed,
      stripe_payment_intent_id: stripe_payment_intent_id,
      stripe_dispute_id: reversal.stripe_dispute_id
    })
    |> written(:restored)
  end

  defp write(settled, _stripe_payment_intent_id, _lines), do: settled

  defp written({:ok, _line}, outcome), do: outcome
  defp written({:error, error}, _outcome), do: {:error, error}

  defp bought(lines), do: lines |> Enum.filter(&(&1.kind == :card_purchase)) |> sum_amounts()

  defp refunded(lines) do
    lines
    |> Enum.filter(&(&1.kind == :card_reversal and is_nil(&1.stripe_dispute_id)))
    |> Enum.sum_by(& &1.stripe_amount_atomic)
  end

  # Every refund, and every dispute not closed in the buyer's disfavour.
  defp claimed(lines) do
    lines
    |> Enum.filter(&(&1.kind == :card_reversal))
    |> Enum.reject(&(&1.stripe_dispute_id && dispute_closed?(lines, &1.stripe_dispute_id)))
    |> Enum.sum_by(& &1.stripe_amount_atomic)
  end

  defp taken(lines) do
    lines
    |> Enum.filter(&(&1.kind in [:card_reversal, :dispute_restore]))
    |> sum_amounts()
    |> Kernel.-()
  end

  defp sum_amounts(lines), do: Enum.sum_by(lines, & &1.amount_atomic)

  defp dispute_reversal(lines, dispute_id),
    do: Enum.find(lines, &(&1.kind == :card_reversal and &1.stripe_dispute_id == dispute_id))

  defp dispute_closed?(lines, dispute_id),
    do: Enum.any?(lines, &(&1.kind == :dispute_restore and &1.stripe_dispute_id == dispute_id))

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

  defp hold(name) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "patchbay credits " <> name
    ])
  end
end
