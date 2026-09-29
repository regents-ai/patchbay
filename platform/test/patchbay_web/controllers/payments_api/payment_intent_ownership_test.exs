defmodule PatchbayWeb.PaymentsAPI.PaymentIntentOwnershipTest do
  # Patchbay's doors to a payment intent answer only its payer. Who may read
  # or change the record itself is the payments library's, and its own tests
  # cover it.
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Identity
  alias Patchbay.Payments.AgentTip
  alias PatchbayWeb.Plugs.CurrentProfile

  setup do
    payer = profile("a")
    other = profile("b")

    {:ok, intent} =
      RegentPayments.Purchase.prepare(
        AgentTip,
        %{amount_atomic: 1_000_000, recipient: other},
        payer
      )

    %{payer: payer, other: other, intent: intent}
  end

  test "HTTP owner read succeeds and another payer cannot distinguish an absent intent",
       context do
    owner = signed_in(context.conn, context.payer)
    body = owner |> get(~p"/api/payment_intents/#{context.intent.id}") |> json_response(200)
    assert body["id"] == context.intent.id
    assert body["amount_usdc"] == "1.00"

    stranger = signed_in(build_conn(), context.other)
    hidden = stranger |> get(~p"/api/payment_intents/#{context.intent.id}") |> json_response(404)

    absent =
      stranger |> get(~p"/api/payment_intents/#{Ecto.UUID.generate()}") |> json_response(404)

    assert hidden == absent
    refute Map.has_key?(hidden, "id")
    refute Map.has_key?(hidden, "payload")
  end

  test "another payer cannot execute the intent or change its state", context do
    body =
      context.conn
      |> signed_in(context.other)
      |> post(~p"/api/payment_intents/#{context.intent.id}/execute", %{})
      |> json_response(404)

    refute Map.has_key?(body, "id")

    assert {:ok, unchanged} =
             RegentPayments.get_payment_intent(context.intent.id, actor: context.payer)

    assert unchanged.status == :prepared
    assert unchanged.payload == context.intent.payload
  end

  test "anonymous HTTP reads require sign-in", context do
    body =
      context.conn |> get(~p"/api/payment_intents/#{context.intent.id}") |> json_response(401)

    assert body["error"]["code"] == "sign_in_required"
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id)
  end

  defp profile(letter) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:ownership-#{letter}-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate(letter, 40)
    })
  end
end
