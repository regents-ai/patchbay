defmodule PatchbayWeb.AgentPairingReadTest do
  # Before it gives an agent a hello card, the sign-in service asks this site
  # whether the agent is paired here (POST /api/agents/v1/pairing) with a token
  # it signed for this site's address. The keys it publishes are kept for the
  # whole node and the Privy application is set for the whole node, so these
  # run one at a time.
  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.SignedAgent

  @keys {RegentAgents.HelloCard, :keys}
  # The Privy application SignedAgent.pair!/2 signs its person in with.
  @app "test-app"

  setup do
    :persistent_term.erase(@keys)
    on_exit(fn -> :persistent_term.erase(@keys) end)

    privy = Application.get_env(:patchbay, :privy, [])
    Application.put_env(:patchbay, :privy, Keyword.put(privy, :app_id, @app))
    on_exit(fn -> Application.put_env(:patchbay, :privy, privy) end)

    key = new_key()

    Req.Test.stub(RegentAgents.Broker, fn %{request_path: "/.well-known/jwks.json"} = conn ->
      Req.Test.json(conn, %{"keys" => [key.jwk]})
    end)

    %{key: key, agent: SignedAgent.pair!()}
  end

  test "the sign-in service hears a paired agent's name, its person's profile code and when it paired",
       %{conn: conn, key: key, agent: agent} do
    subject = subject(agent.wallet)
    {:ok, profile_id} = RegentIdentity.profile_id(@app, agent.owner.privy_user_id)

    assert {200, answer} = ask(conn, sign(key, claims(subject)), subject)

    assert answer == %{
             "name" => "Fixture",
             "person" => profile_id,
             "pairedAt" =>
               agent.pairing.paired_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }
  end

  test "a token the sign-in service did not sign for this site and this agent is refused",
       %{conn: conn, key: key, agent: agent} do
    subject = subject(agent.wallet)

    refused = [
      sign(key, claims(subject, %{"aud" => "https://open.patchbay.help"})),
      sign(key, claims(subject, %{"iss" => "https://siwa.example"})),
      sign(new_key(), claims(subject)),
      sign(key, claims(subject("0x" <> String.duplicate("3", 40))))
    ]

    for token <- refused do
      assert {401, %{"error" => %{"code" => "service_token_invalid"}}} =
               ask(conn, token, subject)
    end
  end

  defp ask(conn, token, subject) do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/agents/v1/pairing", Jason.encode!(%{"subject" => subject}))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp subject(wallet), do: "eip155:8453:" <> wallet

  # The service token as the sign-in service signs it: issued by the sign-in
  # address, for this site's own address, good for a minute.
  defp claims(subject, changes \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "iss" => Application.fetch_env!(:regent_agents, :siwa)[:url],
        "aud" => PatchbayWeb.Endpoint.url(),
        "sub" => subject,
        "iat" => now,
        "exp" => now + 60,
        "jti" => encode(:crypto.strong_rand_bytes(16))
      },
      changes
    )
  end

  # An Ed25519 key as the sign-in service publishes it, `kid` its RFC 7638 thumbprint.
  defp new_key do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    x = encode(public)
    kid = encode(:crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"#{x}"})))

    %{
      seed: seed,
      jwk: %{
        "kty" => "OKP",
        "crv" => "Ed25519",
        "alg" => "EdDSA",
        "use" => "sig",
        "kid" => kid,
        "x" => x
      }
    }
  end

  defp sign(key, claims) do
    header =
      encode(
        Jason.encode!(%{"alg" => "EdDSA", "typ" => "siwa-service+jwt", "kid" => key.jwk["kid"]})
      )

    payload = encode(Jason.encode!(claims))
    signature = :crypto.sign(:eddsa, :none, header <> "." <> payload, [key.seed, :ed25519])
    Enum.join([header, payload, encode(signature)], ".")
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
