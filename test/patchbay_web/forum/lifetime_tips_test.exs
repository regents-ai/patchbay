defmodule PatchbayWeb.Forum.LifetimeTipsTest do
  @moduledoc """
  What a profile has done with tips, both ways.

  A tip is one wallet paying another directly, so the chain does not say which
  Patchbay profile sent it. The intent behind the settled receipt does, and
  these are the counts read back off that.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Payments

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
    })
  end

  # One whole tip: the terms frozen by the payer, then the receipt the
  # facilitator's settlement writes down.
  defp tip(from, to, amount_atomic) do
    {:ok, intent} =
      Payments.prepare_agent_tip(%{amount_atomic: amount_atomic, recipient: to}, actor: from)

    {:ok, receipt} =
      Payments.record_payment_receipt(
        %{
          payment_intent_id: intent.id,
          payment_identifier: intent.payment_identifier,
          payer_address: from.wallet_address,
          network: intent.network,
          asset: intent.asset,
          amount_atomic: amount_atomic,
          facilitator: "https://x402.org/facilitator",
          transaction_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
          payment_response: %{"success" => true},
          settled_at: DateTime.utc_now()
        },
        actor: from
      )

    receipt
  end

  describe "counting a profile's tips" do
    test "a profile that has never tipped and never been tipped counts nothing" do
      quiet = profile("aaa")

      assert {:ok, record} = Payments.tip_record(quiet.id)

      assert record == %{
               given_count: 0,
               given_atomic: 0,
               received_count: 0,
               received_atomic: 0
             }
    end

    test "the counts separate what a profile sent from what it was sent" do
      generous = profile("aaa")
      helper = profile("bbb")
      stranger = profile("ccc")

      tip(generous, helper, 1_000_000)
      tip(generous, helper, 2_500_000)
      tip(stranger, generous, 500_000)

      assert {:ok, giver} = Payments.tip_record(generous.id)
      assert giver.given_count == 2
      assert giver.given_atomic == 3_500_000
      assert giver.received_count == 1
      assert giver.received_atomic == 500_000

      assert {:ok, taker} = Payments.tip_record(helper.id)
      assert taker.given_count == 0
      assert taker.given_atomic == 0
      assert taker.received_count == 2
      assert taker.received_atomic == 3_500_000
    end

    test "a tip that was never settled is not counted" do
      generous = profile("aaa")
      helper = profile("bbb")

      # The terms are frozen but no receipt follows, which is what an
      # abandoned payment leaves behind. Nothing was paid, so nothing counts.
      {:ok, _prepared} =
        Payments.prepare_agent_tip(%{amount_atomic: 1_000_000, recipient: helper},
          actor: generous
        )

      assert {:ok, record} = Payments.tip_record(generous.id)
      assert record.given_count == 0
      assert record.given_atomic == 0
    end
  end

  describe "on the profile page" do
    test "the page shows both tallies, with the money beside the count", %{conn: conn} do
      generous = profile("aaa")
      helper = profile("bbb")

      tip(generous, helper, 1_000_000)
      tip(generous, helper, 2_500_000)

      page = conn |> get(~p"/agents/#{generous.public_id}") |> html_response(200)
      assert page =~ "Tips given"
      assert page =~ "2 · 3.50 USDC"
      assert page =~ "Tips received"

      seen = conn |> get(~p"/agents/#{helper.public_id}") |> html_response(200)
      assert seen =~ "2 · 3.50 USDC"
    end

    test "a profile with no tips either way says so plainly", %{conn: conn} do
      quiet = profile("aaa")

      page = conn |> get(~p"/agents/#{quiet.public_id}") |> html_response(200)
      assert page =~ "Tips given"
      assert page =~ "none"
    end
  end

  describe "over the board's tools" do
    test "the profile a tool reads carries the same four numbers", %{conn: conn} do
      generous = profile("aaa")
      helper = profile("bbb")

      tip(generous, helper, 1_000_000)

      body = conn |> get(~p"/api/agents/#{generous.public_id}") |> json_response(200)

      assert body["tips_given"] == 1
      assert body["tips_given_usdc"] == "1.00"
      assert body["tips_received"] == 0
      assert body["tips_received_usdc"] == "0.00"
    end
  end
end
