defmodule Patchbay.AssistFixtures do
  @moduledoc """
  Assists for tests. `paired_agent/0` is a SIWA-signed agent paired with a
  person, as the agent door signs it in, for tests that open free runs the
  way that door does. `browser_run/1` writes a run straight into the table in
  the shape a free run asked from the page left behind: open, asked by a
  browser and, when `payer_profile_id` is given, by a signed-in person.
  `paid_run/2` writes a run bought before paid assists ended, with the
  payment that bought it, and `paid_payment/2` such a payment that settled
  and opened no run.
  """

  alias Patchbay.Agents.Actor
  alias Patchbay.Assist.Run
  alias Patchbay.Identity
  alias Patchbay.SettledPayment
  alias PatchbayWeb.SignedAgent
  alias RegentPayments.PaymentIntent
  alias RegentPayments.Steps
  alias RegentPayments.USDC

  # What a paid assist cost, in USDC's atomic units.
  @fee_atomic 100_000

  @doc "The request every fixture run asks for."
  def request do
    %{
      "goal" => "Book the 9am table for two on Friday",
      "site_url" => "https://bookings.example.com/app",
      "error" => nil,
      "believed_calls" => [],
      "sign_in" => "unknown"
    }
  end

  @doc "A SIWA-signed agent paired with a new person."
  def paired_agent do
    %{owner: owner, account: account, wallet: wallet, pairing: pairing} = SignedAgent.pair!()
    profile = Identity.upsert_from_wallet!(%{wallet_address: wallet})
    Actor.new(profile, owner, account, pairing)
  end

  @doc "An open run the page asked for, with `attrs` over the defaults."
  def browser_run(attrs \\ %{}) do
    request = request()

    Ash.Seed.seed!(
      Run,
      Map.merge(
        %{
          browser_session_id: Ash.UUID.generate(),
          grant: :visitor,
          visitor_key: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          deposit_status: :no_fee,
          goal: request["goal"],
          site_url: request["site_url"],
          sign_in: :unknown,
          believed_calls: []
        },
        attrs
      )
    )
  end

  @doc """
  An open run bought before paid assists ended, as such a run stands in the
  tables: the `jev_assist` payment `payer` made into the wallet `pay_to`,
  settled and applied, and the run it opened, waiting to be started, with
  its fee still to forward.
  """
  def paid_run(payer, pay_to) do
    request = request()
    settled = paid_payment(payer, pay_to)
    {:ok, _applied} = Steps.step(settled, :mark_applied, payer)

    Ash.Seed.seed!(Run, %{
      id: settled.target_id,
      payment_intent_id: settled.id,
      payer_profile_id: payer.id,
      grant: :paid,
      deposit_status: :pending,
      goal: request["goal"],
      site_url: request["site_url"],
      sign_in: :unknown,
      believed_calls: []
    })
  end

  @doc """
  A `jev_assist` payment `payer` made into the wallet `pay_to` before paid
  assists ended, settled, naming the run it was to open, which never opened.
  """
  def paid_payment(payer, pay_to) do
    request = request()
    run_id = Ash.UUID.generate()
    payload = %{"run_id" => run_id, "request" => request, "pay_to_address" => pay_to}

    intent =
      Ash.Seed.seed!(PaymentIntent, %{
        site: RegentPayments.site(),
        kind: :jev_assist,
        actor_profile_id: payer.id,
        target_type: :assist_run,
        target_id: run_id,
        amount_atomic: @fee_atomic,
        asset: USDC.asset(),
        network: USDC.network(),
        payload: payload,
        payload_digest:
          :sha256 |> :crypto.hash(Jason.encode!(payload)) |> Base.encode16(case: :lower),
        recipient_snapshot: [%{"wallet_address" => pay_to, "amount_atomic" => @fee_atomic}],
        effect_summary:
          "Ask Patchbay to work out the right tool call on bookings.example.com for 0.10 USDC",
        expires_at: DateTime.add(DateTime.utc_now(), 15 * 60, :second)
      })

    {settled, _receipt} = SettledPayment.settle!(intent, payer)
    settled
  end
end
