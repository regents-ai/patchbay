defmodule PatchbayWeb.AgentWhoamiTest do
  # A signed agent asking who it is gets its status and what it may do here, in
  # each of the three states: nobody paired it, its person hasn't signed in
  # here, or it is paired with someone who has.
  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
  end

  test "an agent nobody paired is told it is not paired and how to pair", %{conn: conn} do
    stranger = %{wallet: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)}

    data = whoami(conn, stranger)

    assert %{"authenticated" => true, "status" => "not_paired", "pairing" => nil} = data
    assert data["agent"]["wallet"] == stranger.wallet
    assert data["allowed"] == allowed("not_paired")
    assert data["next_step"] == RegentAgents.HTTP.next_step("not_paired")
  end

  test "an agent whose person has never signed in here is told so", %{conn: conn} do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    person = %RegentAgents.Person{
      privy_user_id: "did:privy:elsewhere-#{System.unique_integer([:positive])}"
    }

    code = RegentAgents.issue_pairing_code!(actor: person)

    pairing =
      RegentAgents.pair_agent!(code.code, "Fixture", :codex,
        actor: %RegentAgents.Agent{wallet: wallet}
      )

    data = whoami(conn, %{wallet: wallet})

    assert %{"status" => "person_not_here", "pairing" => %{"id" => pairing_id}} = data
    assert pairing_id == pairing.id
    assert data["allowed"] == allowed("person_not_here")
    assert data["next_step"] == RegentAgents.HTTP.next_step("person_not_here")
  end

  test "a paired agent whose person signed in here is told it is paired", %{conn: conn} do
    agent = SignedAgent.pair!()

    data = whoami(conn, agent)

    assert %{"status" => "paired", "pairing" => %{"id" => pairing_id}, "next_step" => nil} =
             data

    assert pairing_id == agent.pairing.id
    assert data["allowed"] == allowed("paired")
  end

  defp whoami(conn, agent) do
    conn
    |> SignedAgent.sign(agent)
    |> get("/api/agents/v1/whoami")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp allowed(status), do: Map.fetch!(Application.fetch_env!(:regent_agents, :allowed), status)
end
