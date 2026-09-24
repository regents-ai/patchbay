defmodule PatchbayWeb.DisputeWonTest do
  @moduledoc """
  A card dispute Stripe closes without the money leaving gives back what its
  reversal took and no refund has taken since, once, however often or in
  whatever order Stripe sends the events, to the balance it was taken from
  even after the buyer pairs with a person, and leaves every other line on
  that balance as it was.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.PaymentsAPI.Purchase

  setup do
    previous_stripe = Application.get_env(:patchbay, :stripe)
    previous_escrow = Application.get_env(:patchbay, :escrow)

    Application.put_env(:patchbay, :stripe,
      secret_key: "sk_test_disputes",
      webhook_secret: "whsec_test_disputes"
    )

    Application.put_env(:patchbay, :escrow, contract_address: "0x" <> String.duplicate("e", 40))

    on_exit(fn ->
      Application.put_env(:patchbay, :stripe, previous_stripe)
      Application.put_env(:patchbay, :escrow, previous_escrow)
    end)
  end

  test "a won dispute gives back what it took once, to the balance it was taken from" do
    payment = "pi_" <> Ecto.UUID.generate()
    agent = Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("a", 40)})

    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:dispute-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    {:ok, :credited} = Credits.record_card_purchase(agent.id, 1_000, payment)
    {:ok, :credited} = Credits.record_card_purchase(person.id, 500, "pi_" <> Ecto.UUID.generate())

    # Spending that has nothing to do with the dispute.
    spend(agent, "4.00")
    assert Credits.balance_atomic(agent.id) == 6_000_000

    # Won before its opening has arrived: refused, for Stripe to send again.
    assert webhook(closed(payment, "won")).status == 500
    assert Credits.balance_atomic(agent.id) == 6_000_000

    assert webhook(opened(payment, 1_000)).status == 200
    assert Credits.balance_atomic(agent.id) == -4_000_000

    # The buyer pairs before the dispute is decided; what it holds, below
    # zero, moves onto the person.
    {:ok, %{code: code}} = Pairing.issue(person)
    {:ok, _person} = Pairing.pair(agent, code)
    assert Credits.balance_atomic(person.id) == 1_000_000

    assert webhook(closed(payment, "won")).status == 200
    assert webhook(closed(payment, "won")).status == 200
    assert webhook(opened(payment, 1_000)).status == 200

    # 5 of the person's own, 10 bought, 4 spent: the dispute is as if it never was.
    assert Credits.balance_atomic(person.id) == 11_000_000
    assert [%{kind: :dispute_restore, amount_atomic: 10_000_000} | _] = Credits.history(person)

    # A lost dispute leaves its reversal standing.
    other = "pi_" <> Ecto.UUID.generate()
    {:ok, :credited} = Credits.record_card_purchase(person.id, 200, other)
    assert webhook(opened(other, 200, "du_lost")).status == 200
    assert webhook(closed(other, "lost", "du_lost")).status == 200
    assert Credits.balance_atomic(person.id) == 11_000_000
  end

  test "a refund arriving after the dispute that took the same money is never given back" do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:dispute-#{Ecto.UUID.generate()}",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    payment = "pi_" <> Ecto.UUID.generate()
    {:ok, :credited} = Credits.record_card_purchase(person.id, 1_000, payment)

    assert webhook(opened(payment, 1_000)).status == 200
    assert webhook(refunded(person.id, payment, 1_000)).status == 200
    assert Credits.balance_atomic(person.id) == 0

    # Won, but the money went back to the buyer as a refund: nothing to give back.
    assert webhook(closed(payment, "won")).status == 200
    assert webhook(closed(payment, "won")).status == 200
    assert Credits.balance_atomic(person.id) == 0

    # Part refunded, then an inquiry on the rest closes: the rest comes back.
    other = "pi_" <> Ecto.UUID.generate()
    {:ok, :credited} = Credits.record_card_purchase(person.id, 1_000, other)
    assert webhook(opened(other, 1_000, "du_inquiry")).status == 200
    assert webhook(refunded(person.id, other, 400)).status == 200
    assert Credits.balance_atomic(person.id) == 0
    assert webhook(closed(other, "warning_closed", "du_inquiry")).status == 200
    assert Credits.balance_atomic(person.id) == 6_000_000
  end

  defp refunded(profile_id, payment, cents) do
    object = %{
      "metadata" => %{"patchbay_profile_id" => profile_id},
      "payment_intent" => payment,
      "amount_refunded" => cents
    }

    %{"type" => "charge.refunded", "data" => %{"object" => object}}
  end

  defp spend(agent, amount) do
    {:ok, found} =
      Purchase.special_post_on_offer(agent, %{
        "origin" => "https://dispute-#{Ecto.UUID.generate()}.invalid",
        "tool_name" => "checkout",
        "verdict" => "verified_failure",
        "note" => "The cart never changed.",
        "amount_usdc" => amount
      })

    request = %{payment: :credits, payer: agent.wallet_address, browser_session_id: nil}
    {:applied, _applied, _receipt} = Purchase.execute(agent, found.id, request)
  end

  defp opened(payment, cents, dispute \\ "du_won"),
    do: dispute_event("charge.dispute.created", %{"amount" => cents}, payment, dispute)

  defp closed(payment, status, dispute \\ "du_won"),
    do: dispute_event("charge.dispute.closed", %{"status" => status}, payment, dispute)

  defp dispute_event(type, fields, payment, dispute) do
    object = Map.merge(%{"id" => dispute <> payment, "payment_intent" => payment}, fields)
    %{"type" => type, "data" => %{"object" => object}}
  end

  defp webhook(event) do
    body = Jason.encode!(event)
    now = System.system_time(:second)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{now},v1=#{Patchbay.Stripe.sign("#{now}.#{body}")}")
    |> post("/webhooks/stripe", body)
  end
end
