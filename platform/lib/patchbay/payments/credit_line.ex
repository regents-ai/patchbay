defmodule Patchbay.Payments.CreditLine do
  @moduledoc """
  One line on a profile's Patchbay Credits ledger.

  Lines are written on the profile that holds the balance: a person, or an
  agent paired with nobody. An agent paired with a person spends, and is
  paid, on that person's lines.

  A balance is never stored: it is the sum of its lines, positive for credits
  bought and negative for credits taken back or spent. Lines are only ever
  added. Every card payment they come from is named by its Stripe payment
  intent, so the ledger can always be read against Stripe's own records, and
  every spend names the payment intent it paid for, and every bounty payout
  the report whose bounty it pays.

  The unique Stripe payment intent on a purchase, the unique dispute on a
  reversal, the unique payment intent on a spend and the one payout per
  report are what stop a retried event or a repeated call from being counted
  twice, and a bounty from being both awarded and taken back.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Payments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("credit_lines")
    repo(Patchbay.Repo)

    identity_wheres_to_sql(
      one_purchase_per_card_payment: "kind = 'card_purchase'",
      one_spend_per_payment: "kind = 'spend'",
      one_payout_per_bounty: "kind IN ('bounty_award', 'bounty_return')"
    )

    custom_indexes do
      index([:profile_id])
      index([:stripe_payment_intent_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:kind, Patchbay.Payments.Types.CreditLineKind, allow_nil?: false, public?: true)

    # USDC's atomic units, so one credit is 1_000_000 and a line compares
    # directly with what an action costs in USDC. Negative takes credits away.
    attribute(:amount_atomic, :integer, allow_nil?: false, public?: true)

    # The card payment a purchase or a reversal comes from; empty on every
    # other line.
    attribute(:stripe_payment_intent_id, :string, allow_nil?: true, public?: true)

    # Set on a reversal Stripe opened for a dispute; empty on one for a refund.
    attribute(:stripe_dispute_id, :string, allow_nil?: true, public?: true)

    # The paid priority report whose bounty a payout pays; empty on every
    # other line. It names a row in another domain rather than pointing at one.
    attribute(:report_id, :uuid, allow_nil?: true, public?: true)

    create_timestamp(:inserted_at, public?: true)
  end

  identities do
    identity(:one_purchase_per_card_payment, [:stripe_payment_intent_id],
      where: expr(kind == :card_purchase),
      eager_check?: false
    )

    identity(:one_reversal_per_dispute, [:stripe_dispute_id], eager_check?: false)

    identity(:one_spend_per_payment, [:payment_intent_id],
      where: expr(kind == :spend),
      eager_check?: false
    )

    identity(:one_payout_per_bounty, [:report_id],
      where: expr(kind in [:bounty_award, :bounty_return]),
      eager_check?: false
    )
  end

  relationships do
    belongs_to(:profile, Patchbay.Identity.AgentProfile, allow_nil?: false, public?: true)

    # The paid action a spend paid for; empty on every other line.
    belongs_to(:payment_intent, Patchbay.Payments.PaymentIntent, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    read :for_card_payment do
      description("The lines one Stripe payment intent has written, whoever they belong to.")

      argument(:stripe_payment_intent_id, :string, allow_nil?: false)
      filter(expr(stripe_payment_intent_id == ^arg(:stripe_payment_intent_id)))
    end

    read :spend_for_payment do
      description("The spend one payment intent was paid with, if it was paid in credits.")

      argument(:payment_intent_id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(kind == :spend and payment_intent_id == ^arg(:payment_intent_id)))
    end

    read :history do
      description("The signed-in profile's own lines, newest first.")

      filter(expr(profile_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc], limit: 50))
    end

    create :record_card_purchase do
      description("Credits bought by a card payment Stripe has taken.")

      accept([:profile_id, :amount_atomic, :stripe_payment_intent_id])
      require_attributes([:stripe_payment_intent_id])
      change(set_attribute(:kind, :card_purchase))
      validate(compare(:amount_atomic, greater_than: 0))
    end

    create :record_card_reversal do
      description("Credits taken back because Stripe refunded or disputed the card payment.")

      accept([:profile_id, :amount_atomic, :stripe_payment_intent_id, :stripe_dispute_id])
      require_attributes([:stripe_payment_intent_id])
      change(set_attribute(:kind, :card_reversal))
      validate(compare(:amount_atomic, less_than: 0))
    end

    create :record_spend do
      description("""
      Credits spent on a payment intent, written on the balance the payer
      spends: `Credits.spend/2` names the payer's own intent, locked, after
      checking that balance under its lock.
      """)

      accept([:profile_id, :payment_intent_id, :amount_atomic])
      require_attributes([:payment_intent_id])
      change(set_attribute(:kind, :spend))
      validate(compare(:amount_atomic, less_than: 0))
    end

    create :record_pairing_move do
      description("""
      One side of an agent's own credits moving onto the person it paired
      with: negative on the agent, positive on the person.
      """)

      accept([:profile_id, :amount_atomic])
      change(set_attribute(:kind, :pairing_move))
      validate(negate(attribute_equals(:amount_atomic, 0)))
    end

    create :record_bounty_payout do
      description("""
      A bounty held in credits paid out, once per report: awarded to the
      author of the accepted answer, or returned to the asker.
      """)

      accept([:profile_id, :report_id, :kind, :amount_atomic])
      require_attributes([:report_id])
      validate(one_of(:kind, [:bounty_award, :bounty_return]))
      validate(compare(:amount_atomic, greater_than: 0))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(expr(profile_id == ^actor(:id)))
    end

    # Every line is written by `Patchbay.Payments.Credits` alone, from
    # Stripe's signed word, a payer's own locked intent, a bounty's own rule or
    # a pairing, so no request can write one in its own words.
  end
end
