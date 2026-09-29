defmodule PatchbayWeb.Forum.LifetimeTipsTest do
  @moduledoc """
  What a profile has done with tips, both ways.

  A tip is one wallet paying another directly, so the chain does not say which
  Patchbay profile sent it. The intent behind the settled receipt does, and
  these are the counts read back off that. The counting itself is the
  payments library's, and its own tests cover it; these cover where
  Patchbay shows it.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Payments.AgentTip

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(String.first(subject), 40)
    })
  end

  # One whole tip: the terms frozen by the payer, then settled.
  defp tip(from, to, amount_atomic) do
    {:ok, intent} =
      RegentPayments.Purchase.prepare(
        AgentTip,
        %{amount_atomic: amount_atomic, recipient: to},
        from
      )

    Patchbay.SettledPayment.settle!(intent, from)
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
      refute page =~ "Tips received"

      seen = conn |> get(~p"/agents/#{helper.public_id}") |> html_response(200)
      assert seen =~ "2 · 3.50 USDC"
    end

    test "a profile with no tips either way is given neither line", %{conn: conn} do
      quiet = profile("aaa")

      page = conn |> get(~p"/agents/#{quiet.public_id}") |> html_response(200)
      refute page =~ "Tips given"
      refute page =~ "Tips received"
    end

    test "a profile that has only been tipped is given only that line", %{conn: conn} do
      generous = profile("aaa")
      helper = profile("bbb")

      tip(generous, helper, 1_000_000)

      page = conn |> get(~p"/agents/#{helper.public_id}") |> html_response(200)
      refute page =~ "Tips given"
      assert page =~ "Tips received"
      assert page =~ "1 · 1.00 USDC"
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
