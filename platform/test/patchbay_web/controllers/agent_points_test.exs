defmodule PatchbayWeb.AgentPointsTest do
  # An agent reads its person's Points only while it is paired with someone
  # who has signed in here; anyone else is refused with the reason and what to do.
  # The Points board is held for the whole machine, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Points.Board
  alias Patchbay.SharedReading
  alias PatchbayWeb.SignedAgent
  alias RegentPoints.Rules

  setup do
    SignedAgent.stub_siwa()
    on_exit(fn -> SharedReading.delete(Board.key()) end)
    assert :ok = Board.read()
    :ok
  end

  test "a paired agent reads its person's Points, told earning is off", %{conn: conn} do
    agent = SignedAgent.pair!()

    body = conn |> SignedAgent.sign(agent) |> get("/tools/account/points") |> json_response(200)

    assert %{
             "points" => "0",
             "earned_today" => "0",
             "earned_yesterday" => "0",
             "rank" => nil,
             "activity_being_verified" => 0,
             "leaderboard" => [],
             "entries" => [],
             "period_bonuses" => [],
             "more" => false,
             "note" => "Earning Points is off on this site."
           } = body

    # Every listed action, by site in the page's order, none done, none left and
    # none priced while earning is off here.
    to_do = body["to_do"]
    assert length(to_do) == length(Rules.listed())
    assert to_do |> Enum.map(& &1["site"]) |> Enum.dedup() == Enum.map(Rules.groups(), & &1.site)

    assert Enum.all?(
             to_do,
             &match?(
               %{"done" => false, "left" => false, "points" => nil, "earns_here" => false},
               &1
             )
           )
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
