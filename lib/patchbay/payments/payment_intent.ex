defmodule Patchbay.Payments.PaymentIntent do
  @moduledoc """
  The terms of one paid action, settled before anyone is asked to pay for it.

  Everything that decides what the money does — the amount, the wallet it
  travels to, and the sentence describing the effect — is written when the
  intent is prepared and never rewritten. Only the status moves after that, so
  a payer signs for exactly what they were shown and `payload_digest` is the
  proof of it.

  Patchbay never holds the money. The payment goes from the payer's wallet to
  the recipient's; this row records what was promised, and the receipt beside
  it records what happened.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Payments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Patchbay.Payments.Types.PaymentIntentStatus
  alias Patchbay.Payments.Types.PaymentKind
  alias Patchbay.Payments.Types.PaymentTargetType
  alias Patchbay.Payments.USDC

  # The floor keeps a tip worth more than the gas that moves it; the ceiling is
  # what one call may spend without a person deciding.
  @min_amount_atomic 100_000
  @max_amount_atomic 20_000_000

  postgres do
    table("payment_intents")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    # What the payer's wallet and the facilitator both call this payment. It is
    # the intent's own id in string form, so a signature can be tied back to
    # one row and to no other.
    attribute(:payment_identifier, :string, allow_nil?: false, public?: true)

    attribute(:kind, PaymentKind, allow_nil?: false, public?: true)

    # The paying profile. It names a row in the identity domain rather than
    # pointing at one, so a payment record outlives the profile it was made by.
    attribute(:actor_profile_id, :uuid, allow_nil?: false, public?: true)

    attribute(:target_type, PaymentTargetType, allow_nil?: false, public?: true)
    attribute(:target_id, :uuid, allow_nil?: false, public?: true)

    attribute(:amount_atomic, :integer, allow_nil?: false, public?: true)
    attribute(:asset, :string, allow_nil?: false, public?: true)
    attribute(:network, :string, allow_nil?: false, public?: true)

    # The frozen effect: who is credited, at which wallet, and how much.
    attribute(:payload, :map, allow_nil?: false, public?: true)

    attribute :payload_digest, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 64, max_length: 64, match: ~r/\A[0-9a-f]{64}\z/)
    end

    attribute(:recipient_snapshot, {:array, :map}, allow_nil?: false, public?: true)
    attribute(:effect_summary, :string, allow_nil?: false, public?: true)

    attribute(:status, PaymentIntentStatus,
      allow_nil?: false,
      public?: true,
      default: :prepared
    )

    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_payment_identifier, [:payment_identifier])
  end

  relationships do
    has_one(:receipt, Patchbay.Payments.PaymentReceipt)
  end

  actions do
    defaults([:read])

    read :for_update do
      description("The intent held under a row lock, so it can only be settled once.")
      prepare(build(lock: :for_update, load: [:receipt]))
    end

    create :prepare_agent_tip do
      description("Freezes the terms of a tip from one agent profile to another.")

      accept([:amount_atomic])

      argument(:recipient, :struct,
        allow_nil?: false,
        constraints: [instance_of: Patchbay.Identity.AgentProfile],
        description: "The profile being tipped, as it stands at this moment."
      )

      # The payer is whoever is signed in, never a value the request carries,
      # so no caller can prepare a payment in somebody else's name.
      change(set_attribute(:actor_profile_id, actor(:id)))

      change(set_attribute(:kind, :agent_tip))
      change(set_attribute(:target_type, :agent_profile))
      change(set_attribute(:asset, USDC.asset()))
      change(set_attribute(:network, USDC.network()))

      validate(
        compare(:amount_atomic,
          greater_than_or_equal_to: @min_amount_atomic,
          less_than_or_equal_to: @max_amount_atomic
        )
      )

      validate(Patchbay.Payments.Validations.RecipientCanBePaid)

      change(Patchbay.Payments.Changes.FreezeAgentTip)
    end

    update :mark_payment_required do
      description("The payer has been handed the terms and asked to sign for them.")
      accept([])
      change(set_attribute(:status, :payment_required))
    end

    update :mark_settlement_pending do
      description("The facilitator was asked to settle and did not say whether it did.")
      accept([])
      change(set_attribute(:status, :settlement_pending))
    end

    update :mark_settled do
      description("The money has moved.")
      accept([])
      change(set_attribute(:status, :settled))
    end

    update :mark_applied do
      description("The effect the payer paid for has been carried out.")
      accept([])
      change(set_attribute(:status, :applied))
    end

    update :mark_failed do
      description("The facilitator refused to settle this payment.")
      accept([])
      change(set_attribute(:status, :failed))
    end

    update :expire do
      description("The terms stood too long unpaid to still be honoured.")
      accept([])
      change(set_attribute(:status, :expired))
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if(actor_present())
    end

    # An intent is only ever reached through the endpoint that owns it, and
    # that endpoint refuses anyone but the payer by name. What the resource
    # adds is that no anonymous caller, and no job that forgot to say who it
    # was acting as, can read one at all.
    policy action_type(:read) do
      authorize_if(actor_present())
    end

    policy action_type(:update) do
      authorize_if(expr(actor_profile_id == ^actor(:id)))
    end
  end

  @doc """
  The smallest tip Patchbay accepts, in whole millionths of a dollar.
  """
  @spec min_amount_atomic() :: pos_integer()
  def min_amount_atomic, do: @min_amount_atomic

  @doc """
  The largest tip Patchbay accepts, in whole millionths of a dollar.
  """
  @spec max_amount_atomic() :: pos_integer()
  def max_amount_atomic, do: @max_amount_atomic
end
