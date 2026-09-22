defmodule Patchbay.Assist.Run do
  @moduledoc """
  One paid assist: what an agent asked Patchbay to work out on some site, the
  payment that bought it, and what came of it.

  A run is opened from the frozen terms of a settled payment and from nothing
  else, so what Patchbay works on is exactly what the payer was shown and paid
  for. It belongs to the payer, who is the only one who can read it back. The
  status and the outcome are the only things that move after it is opened.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Assist,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Assist.Types.Outcome
  alias Patchbay.Assist.Types.RunStatus
  alias Patchbay.Assist.Types.SignIn

  postgres do
    table("assist_runs")
    repo(Patchbay.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    # The paying profile. It names a row in the identity domain rather than
    # pointing at one, so a run outlives the profile it was bought by.
    attribute(:payer_profile_id, :uuid, allow_nil?: false, public?: true)

    # The browser's forum identity the payment was made under; a wallet
    # author has none.
    attribute(:browser_session_id, :uuid, allow_nil?: true, public?: true)

    attribute(:goal, :string, allow_nil?: false, public?: true)
    attribute(:site_url, :string, allow_nil?: false, public?: true)
    attribute(:expected_result, :string, allow_nil?: false, public?: true)
    attribute(:sign_in, SignIn, allow_nil?: false, public?: true)

    # The calls the agent believed would work, each a tool name and its
    # arguments, in the order the agent gave them.
    attribute(:believed_calls, {:array, :map}, allow_nil?: false, public?: true, default: [])

    attribute(:status, RunStatus, allow_nil?: false, public?: true, default: :paid)
    attribute(:outcome, Outcome, allow_nil?: true, public?: true)

    # What was tried, in order: the tool, its arguments, an excerpt of the
    # site's answer and what Jev made of it.
    attribute(:steps, {:array, :map}, allow_nil?: false, public?: true, default: [])

    timestamps()
  end

  identities do
    # One payment buys one run; a second opening of the same payment is
    # refused by the database rather than by a check a retry could race past.
    identity(:one_run_per_payment, [:payment_intent_id], eager_check?: false)
  end

  relationships do
    belongs_to(:payment_intent, Patchbay.Payments.PaymentIntent,
      allow_nil?: false,
      public?: true
    )
  end

  actions do
    defaults([:read])

    create :open do
      description("""
      Opens the run a settled payment bought, from that payment's frozen terms:
      the request as the payer wrote it, under the id the terms named.
      """)

      accept([])

      argument(:intent, :struct,
        allow_nil?: false,
        constraints: [instance_of: Patchbay.Payments.PaymentIntent],
        description: "The settled payment for this assist, as it stands."
      )

      argument(:browser_session_id, :uuid,
        allow_nil?: true,
        description: "The browser's forum identity the settling request carried, if any."
      )

      change(set_attribute(:payer_profile_id, actor(:id)))
      change(set_attribute(:browser_session_id, arg(:browser_session_id)))
      change(Patchbay.Assist.Changes.OpenFromIntent)
    end
  end

  policies do
    # Only the settled payment's own payer opens its run, and only the
    # purchase process holds a settled intent to open one from.
    policy action(:open) do
      authorize_if(actor_present())
    end

    policy action_type(:read) do
      authorize_if(expr(payer_profile_id == ^actor(:id)))
    end
  end
end
