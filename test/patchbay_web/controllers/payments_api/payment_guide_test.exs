defmodule PatchbayWeb.PaymentsAPI.PaymentGuideTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  test "unsigned payment doors say sign-in is required and point at the guide", %{conn: conn} do
    conn = get(conn, ~p"/api/me/usdc_balance")

    assert conn.status == 401
    body = json_response(conn, 401)
    assert body["problem_code"] == "sign_in_required"
    assert body["next_action"] =~ "sign in on the current Patchbay page"
    assert body["payment_help_url"] =~ "/agent-setup#x402"
  end

  test "a signed-in balance names Base funding fields or says payments are not configured", %{
    conn: conn
  } do
    profile =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:guide-test",
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
      |> get(~p"/api/me/usdc_balance")

    body = json_response(conn, conn.status)

    case conn.status do
      200 ->
        assert body["verified_payout_address"] == profile.wallet_address
        assert body["funding"]["chain_id"] == 8453
        assert body["funding"]["asset_contract"] == "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
        assert body["funding"]["wallet_address"] == profile.wallet_address
        assert body["funding"]["warning"] =~ "Never share a private key"

      503 ->
        assert body["problem_code"] == "not_configured"
        assert body["payment_help_url"] =~ "/agent-setup#x402"
        assert body["next_action"] =~ "free Patchbay tools"

      other ->
        flunk("unexpected balance status #{other}: #{inspect(body)}")
    end
  end
end
