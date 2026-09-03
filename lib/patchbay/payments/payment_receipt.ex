defmodule Patchbay.Payments.PaymentReceipt do
  @moduledoc """
  What actually happened when a payment intent was settled: who paid, on which
  chain, and the transaction the facilitator reported.

  One receipt per intent. The unique payment identifier, and the unique
  transaction hash where one came back, are what stop the same payment being
  recorded twice if a call is retried.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Payments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("payment_receipts")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:payment_identifier, :string, allow_nil?: false, public?: true)
    attribute(:payer_address, :string, allow_nil?: false, public?: true)
    attribute(:network, :string, allow_nil?: false, public?: true)
    attribute(:asset, :string, allow_nil?: false, public?: true)
    attribute(:amount_atomic, :integer, allow_nil?: false, public?: true)

    # Which facilitator verified and settled this payment, so a later
    # reconciliation knows whose records to go and read.
    attribute(:facilitator, :string, allow_nil?: false, public?: true)

    # Absent when the facilitator settled without naming a transaction.
    attribute(:transaction_hash, :string, allow_nil?: true, public?: true)

    # The facilitator's answer, kept whole and unedited.
    attribute(:payment_response, :map, allow_nil?: false, public?: true)

    attribute(:settled_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_payment_identifier, [:payment_identifier], eager_check?: false)
    identity(:unique_transaction_hash, [:transaction_hash], eager_check?: false)
  end

  relationships do
    belongs_to(:payment_intent, Patchbay.Payments.PaymentIntent, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    read :earned_by_profile do
      description(
        "The settled tips the given profiles have received, found through each receipt's intent."
      )

      argument(:profile_ids, {:array, :uuid}, allow_nil?: false)

      filter(
        expr(
          payment_intent.kind == :agent_tip and
            payment_intent.target_type == :agent_profile and
            payment_intent.target_id in ^arg(:profile_ids)
        )
      )
    end

    create :record do
      description("Writes down a settled payment exactly as the facilitator reported it.")

      accept([
        :payment_intent_id,
        :payment_identifier,
        :payer_address,
        :network,
        :asset,
        :amount_atomic,
        :facilitator,
        :transaction_hash,
        :payment_response,
        :settled_at
      ])
    end
  end

  policies do
    policy always() do
      authorize_if(actor_present())
    end
  end
end
