defmodule PatchbayWeb.PaymentsAPI.CreditsPaymentTest do
  @moduledoc """
  Paying for a fix from Patchbay Credits on the page: the fee comes off the
  balance once, the run opens with nothing to forward to staking, a balance
  that does not cover the fee pays nothing, and only a fix can be paid this
  way.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Assist
  alias Patchbay.Identity
  alias Patchbay.Payments
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.Plugs.CurrentProfile

  @wallet "0x" <> String.duplicate("d", 40)

  @args %{
    "goal" => "Book the 9am table for two on Friday",
    "site_url" => "https://bookings.example.com/app",
    "sign_in" => "unknown",
    "expected_result" => "A confirmation with a booking reference",
    "believed_calls" => []
  }

  setup do
    old_assist = Application.get_env(:patchbay, :assist)
    Application.put_env(:patchbay, :assist, pay_to_address: @wallet)
    on_exit(fn -> Application.put_env(:patchbay, :assist, old_assist) end)

    %{payer: profile()}
  end

  test "a fix paid from credits takes the fee off the balance once and opens with nothing to forward",
       %{payer: payer} do
    {:ok, :credited} = Credits.record_card_purchase(payer.id, 200, "pi_" <> Ecto.UUID.generate())
    prepared = prepare(payer, "jev_assist", @args)

    applied =
      payer
      |> signed_in()
      |> post(prepared["execute_url"], %{"pay_with" => "credits"})

    assert get_resp_header(applied, "payment-response") == []
    applied = json_response(applied, 200)
    assert applied["status"] == "applied"
    assert applied["paid_with"] == "patchbay_credits"
    refute Map.has_key?(applied, "receipt")
    assert applied["run_id"] == prepared["run_id"]

    assert Credits.balance_atomic(payer.id) == 1_900_000
    assert {:ok, run} = Assist.get_run(prepared["run_id"], actor: payer)
    assert run.deposit_status == :card

    # Asking again pays nothing more.
    again =
      payer
      |> signed_in()
      |> post(prepared["execute_url"], %{"pay_with" => "credits"})
      |> json_response(200)

    assert again["status"] == "applied"
    assert again["paid_with"] == "patchbay_credits"
    assert Credits.balance_atomic(payer.id) == 1_900_000

    read =
      payer
      |> signed_in()
      |> get(~p"/api/payment_intents/#{prepared["id"]}")
      |> json_response(200)

    assert read["paid_with"] == "patchbay_credits"
    assert read["recovery_required"] == false

    assert [%{kind: :spend, amount_atomic: -100_000}, %{kind: :card_purchase}] =
             Credits.history(payer)

    assert [%{what: :jev_assist, paid_in: :credits, amount_atomic: -100_000} | _rest] =
             Payments.payment_history(payer)
  end

  test "a balance that does not cover the fee pays nothing", %{payer: payer} do
    prepared = prepare(payer, "jev_assist", @args)

    short =
      payer
      |> signed_in()
      |> post(prepared["execute_url"], %{"pay_with" => "credits"})
      |> json_response(402)

    assert short["problem_code"] == "credits_short"
    assert short["balance_credits"] == "0.00"
    assert short["error"] =~ "Nothing was charged"

    assert {:ok, %{status: :prepared}} =
             Payments.get_payment_intent(prepared["id"], actor: payer)

    assert {:ok, nil} = Assist.get_run(prepared["run_id"], actor: payer, not_found_error?: false)
  end

  test "a tip is not paid from credits", %{payer: payer} do
    {:ok, :credited} = Credits.record_card_purchase(payer.id, 500, "pi_" <> Ecto.UUID.generate())
    recipient = profile()

    prepared =
      prepare(payer, "agent_tip", %{"amount_usdc" => "1.00", "profile_id" => recipient.public_id})

    refused =
      payer
      |> signed_in()
      |> post(prepared["execute_url"], %{"pay_with" => "credits"})
      |> json_response(402)

    assert refused["reason"] ==
             "Only a fix or a priority report can be paid from Patchbay Credits."

    assert Credits.balance_atomic(payer.id) == 5_000_000
  end

  describe "the fix form once the free fixes are used" do
    setup %{payer: payer} do
      old = Application.get_env(:patchbay, :daily_free_fixes)
      Application.put_env(:patchbay, :daily_free_fixes, 0)
      on_exit(fn -> restore(:daily_free_fixes, old) end)

      old_stripe = Application.get_env(:patchbay, :stripe)
      Application.put_env(:patchbay, :stripe, secret_key: "sk_test", webhook_secret: "whsec_test")
      on_exit(fn -> restore(:stripe, old_stripe) end)

      %{payer: payer}
    end

    test "offers the credits when they cover the fee, and where to buy them when not", %{
      payer: payer
    } do
      short = payer |> signed_in() |> get(~p"/") |> html_response(200)
      refute short =~ "Pay 0.10 from credits"
      assert short =~ "buy Patchbay Credits by card"
      assert short =~ "/agents/#{payer.public_id}#patchbay-credits"

      {:ok, :credited} =
        Credits.record_card_purchase(payer.id, 200, "pi_" <> Ecto.UUID.generate())

      covered = payer |> signed_in() |> get(~p"/") |> html_response(200)
      assert covered =~ "Pay 0.10 from credits"
      assert covered =~ "2.00 left"
      refute covered =~ "buy Patchbay Credits by card"
    end
  end

  defp prepare(payer, kind, args) do
    payer
    |> signed_in()
    |> post(~p"/api/payment_intents", %{kind: kind, args: args})
    |> json_response(201)
  end

  defp profile do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:credits-pay-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("f", 40)
    })
  end

  defp signed_in(profile) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end

  defp restore(setting, nil), do: Application.delete_env(:patchbay, setting)
  defp restore(setting, value), do: Application.put_env(:patchbay, setting, value)
end
