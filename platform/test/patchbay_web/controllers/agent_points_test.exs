defmodule PatchbayWeb.AgentPointsTest do
  # An agent reads its person's Points only while it is paired with someone
  # who has signed in here; anyone else is refused with the reason and what to do.
  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
  end

  test "a paired agent reads its person's Points, told earning is off", %{conn: conn} do
    agent = SignedAgent.pair!()

    body = conn |> SignedAgent.sign(agent) |> get("/tools/account/points") |> json_response(200)

    assert %{
             "points" => "0",
             "earned_today" => "0",
             "pending" => 0,
             "daily_allowances" => [],
             "entries" => [],
             "more" => false,
             "note" => "Earning Points is off on this site."
           } = body
  end

  test "an agent nobody paired is refused as not paired", %{conn: conn} do
    stranger = %{wallet: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)}

    body =
      conn |> SignedAgent.sign(stranger) |> get("/tools/account/points") |> json_response(403)

    assert body["error"]["code"] == "agent_not_paired"
  end

  test "an agent whose person has never signed in here is refused as person not here",
       %{conn: conn} do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    person = %RegentAgents.Person{
      privy_user_id: "did:privy:elsewhere-#{System.unique_integer([:positive])}"
    }

    code = RegentAgents.issue_pairing_code!(actor: person)

    RegentAgents.pair_agent!(code.code, "Fixture", :codex,
      actor: %RegentAgents.Agent{wallet: wallet}
    )

    body =
      conn
      |> SignedAgent.sign(%{wallet: wallet})
      |> get("/tools/account/points")
      |> json_response(403)

    assert body["error"]["code"] == "person_not_here"
  end

  test "an unsigned request is refused before anything is read", %{conn: conn} do
    assert conn |> get("/tools/account/points") |> json_response(401)
  end
end
