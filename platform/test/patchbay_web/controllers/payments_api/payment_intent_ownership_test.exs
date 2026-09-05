defmodule PatchbayWeb.PaymentsAPI.PaymentIntentOwnershipTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Identity
  alias Patchbay.Payments
  alias PatchbayWeb.Plugs.CurrentProfile

  setup do
    payer = profile("a")
    other = profile("b")

    {:ok, intent} =
      Payments.prepare_agent_tip(%{amount_atomic: 1_000_000, recipient: other}, actor: payer)

    %{payer: payer, other: other, intent: intent}
  end

  test "named reads and row locks reveal an intent only to its payer", context do
    for read <- [&Payments.get_payment_intent/2, &Payments.lock_payment_intent/2] do
      assert {:ok, found} = read.(context.intent.id, actor: context.payer)
      assert found.payload == context.intent.payload
      assert found.id == context.intent.id

      assert {:error, _} = read.(context.intent.id, actor: context.other)
      assert {:error, _} = read.(context.intent.id, actor: nil)
    end

    assert {:ok, unchanged} = Payments.get_payment_intent(context.intent.id, actor: context.payer)
    assert unchanged.status == :prepared
    assert unchanged.payload_digest == context.intent.payload_digest
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
    assert {:ok, unchanged} = Payments.get_payment_intent(context.intent.id, actor: context.payer)
    assert unchanged.status == :prepared
    assert unchanged.payload == context.intent.payload
  end

  test "payer can recover an already settled receipt without submitting another payment",
       context do
    hash = "0x" <> String.duplicate("1", 64)

    {:ok, receipt} =
      Payments.record_payment_receipt(
        %{
          payment_intent_id: context.intent.id,
          payment_identifier: context.intent.payment_identifier,
          payer_address: context.payer.wallet_address,
          network: context.intent.network,
          asset: context.intent.asset,
          amount_atomic: context.intent.amount_atomic,
          facilitator: "https://example.invalid/facilitator",
          transaction_hash: hash,
          payment_response: %{
            "success" => true,
            "transaction" => hash,
            "network" => context.intent.network
          },
          settled_at: DateTime.utc_now()
        },
        actor: context.payer
      )

    assert {:ok, _} = Payments.mark_settled(context.intent, actor: context.payer)
    assert {:ok, locked} = Payments.lock_payment_intent(context.intent.id, actor: context.payer)
    assert locked.receipt.id == receipt.id

    body =
      context.conn
      |> signed_in(context.payer)
      |> post(~p"/api/payment_intents/#{context.intent.id}/execute", %{})
      |> json_response(200)

    assert body["payment_intent_id"] == context.intent.id
    assert body["receipt"]["transaction_hash"] == hash
    assert body["amount_usdc"] == "1.00"
  end

  test "anonymous HTTP reads require sign-in", context do
    body =
      context.conn |> get(~p"/api/payment_intents/#{context.intent.id}") |> json_response(401)

    assert body["problem_code"] == "sign_in_required"
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end

  defp profile(letter) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:ownership-#{letter}-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate(letter, 40)
    })
  end
end
