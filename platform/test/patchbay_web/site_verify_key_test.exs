defmodule PatchbayWeb.SiteVerifyKeyTest do
  # Patchbay asks the sign-in service to check a signed agent request with its
  # own verify key, which names the audience. When the service refuses that key,
  # or answers for another site, Patchbay's own settings are wrong: it logs an
  # error and tells the agent the service could not be reached, never that its
  # signature was bad.
  use PatchbayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PatchbayWeb.SignedAgent

  test "a signed request is checked with this site's own key", %{conn: conn} do
    test = self()

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      send(test, {:key, get_req_header(conn, "authorization")})
      Req.Test.json(conn, verdict("patchbay"))
    end)

    conn |> SignedAgent.sign(%{wallet: wallet()}) |> get("/api/agents/v1/me")

    assert_received {:key, ["Bearer test-site-verify-key"]}
  end

  test "the service refusing this site's key is the site's fault", %{conn: conn} do
    Req.Test.stub(RegentAgents.Broker, fn conn ->
      conn |> put_status(401) |> Req.Test.json(%{error: %{code: "site_verify_unauthorized"}})
    end)

    log =
      capture_log(fn ->
        body =
          conn
          |> SignedAgent.sign(%{wallet: wallet()})
          |> get("/api/agents/v1/me")
          |> json_response(503)

        assert body["error"]["code"] == "siwa_request_failed"
      end)

    assert log =~ "verify_key_refused"
  end

  test "a verdict for another site lets nobody in", %{conn: conn} do
    Req.Test.stub(RegentAgents.Broker, &Req.Test.json(&1, verdict("regents")))

    log =
      capture_log(fn ->
        body =
          conn
          |> SignedAgent.sign(%{wallet: wallet()})
          |> get("/api/agents/v1/me")
          |> json_response(503)

        assert body["error"]["code"] == "siwa_request_failed"
      end)

    assert log =~ "audience_mismatch"
  end

  defp verdict(audience) do
    wallet = wallet()

    %{
      code: "http_envelope_valid",
      data: %{
        verified: true,
        walletAddress: wallet,
        chainId: 8453,
        agentRegistration: nil,
        agentBook: nil,
        principal: %{kind: "wallet", wallet_address: wallet, chain_id: 8453, audience: audience}
      }
    }
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
