defmodule PatchbayWeb.PrivateDoorsTest do
  # Two doors that must never open to the wrong person: the saved errors
  # answer only Credits admins, and the account tools answer an agent with its
  # own person's account, never another's.
  #
  # The Credits admin list is application-wide, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures, only: [give_credits: 2]

  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent

  test "the saved errors are not found for anyone but a Credits admin", %{conn: conn} do
    admin = SignedAgent.pair!().owner
    visitor = SignedAgent.pair!().owner

    admins = Application.fetch_env!(:regent_credits, :admins)
    Application.put_env(:regent_credits, :admins, [admin.privy_user_id])
    on_exit(fn -> Application.put_env(:regent_credits, :admins, admins) end)

    assert conn |> get("/admin/errors") |> html_response(404)
    assert conn |> signed_in(visitor) |> get("/admin/errors") |> html_response(404)

    assert conn |> signed_in(admin) |> get("/admin/errors") |> html_response(200)
  end

  test "an agent's account tools show its own person's account and nobody else's",
       %{conn: conn} do
    SignedAgent.stub_siwa()
    mine = SignedAgent.pair!()
    theirs = SignedAgent.pair!()
    give_credits(theirs.owner, "25")

    for {agent, credits} <- [{mine, "0"}, {theirs, "25"}] do
      body =
        conn |> SignedAgent.sign(agent) |> get("/tools/account/balances") |> json_response(200)

      assert body["account_id"] == agent.account.id
      assert body["pairing_id"] == agent.pairing.id
      assert Decimal.equal?(Decimal.new(body["credits"]["available"]), Decimal.new(credits))
    end
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id)
  end
end
