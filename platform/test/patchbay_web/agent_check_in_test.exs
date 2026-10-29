defmodule PatchbayWeb.AgentCheckInTest do
  # An agent that checks in unpaired, or paired to someone who has never signed
  # in here, is refused the way /openapi.json documents it.
  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
  end

  test "an agent nobody paired is refused as documented", %{conn: conn} do
    stranger = %{wallet: wallet()}

    body = conn |> SignedAgent.sign(stranger) |> get("/api/agents/v1/me") |> json_response(403)

    assert body == documented("agentNotPaired")
  end

  test "an agent whose person has never signed in here is refused as documented", %{conn: conn} do
    wallet = wallet()

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
      |> get("/api/agents/v1/me")
      |> json_response(403)

    assert body == documented("personNotHere")
  end

  defp documented(example) do
    get_in(
      Application.app_dir(:patchbay, "priv/public/openapi.json")
      |> File.read!()
      |> Jason.decode!(),
      [
        "paths",
        "/api/agents/v1/me",
        "get",
        "responses",
        "403",
        "content",
        "application/json",
        "examples",
        example,
        "value"
      ]
    )
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
