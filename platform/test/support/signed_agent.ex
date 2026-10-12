defmodule PatchbayWeb.SignedAgent do
  @moduledoc """
  An agent paired with a person, for tests of the doors only a signed, paired
  agent may use.

  `stub_siwa/0` stands in for the SIWA service: it accepts a request carrying
  this module's fixture proof as signed by the wallet the proof names, for
  audience patchbay, and refuses anything else as the service would.
  `pair!/1` makes the person (a local Patchbay profile and the shared Regent
  account) and pairs an agent wallet with them. `sign/2` puts that agent's
  proof and a JSON content type on a request.
  """

  import Plug.Conn

  alias Patchbay.Identity

  @doc "Answers SIWA verification for this test's process."
  @spec stub_siwa() :: :ok
  def stub_siwa, do: Req.Test.stub(RegentAgents.Broker, &verify/1)

  @doc """
  Pairs an agent wallet, `wallet` or a new one, with `owner`, a profile signed
  in through Privy, or with a new person when none is given. The person's
  shared account is established as a Privy sign-in establishes it.
  """
  @spec pair!(Identity.AgentProfile.t() | nil, String.t() | nil) :: map()
  def pair!(owner \\ nil, wallet \\ nil) do
    owner = owner || person!()
    wallet = wallet || wallet()

    {:ok, account} =
      Patchbay.Accounts.establish(%RegentPrivy.Session{
        app_id: "test-app",
        session_id: "test-session",
        privy_user_id: owner.privy_user_id,
        wallet_address: owner.wallet_address,
        wallet_addresses: [owner.wallet_address]
      })

    person = %RegentAgents.Person{privy_user_id: owner.privy_user_id}
    code = RegentAgents.issue_pairing_code!(actor: person)

    pairing =
      RegentAgents.pair_agent!(code.code, "Fixture", :codex,
        actor: %RegentAgents.Agent{wallet: wallet}
      )

    %{owner: owner, account: account, wallet: wallet, pairing: pairing}
  end

  @doc "A request signed by `agent`'s wallet, sending JSON."
  @spec sign(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign(conn, %{wallet: wallet}) do
    conn
    |> put_req_header("x-siwa-signature", "fixture-proof:" <> wallet)
    |> put_req_header("content-type", "application/json")
  end

  defp person! do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:paired-owner-#{System.unique_integer([:positive])}",
      wallet_address: wallet()
    })
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp verify(conn) do
    {:ok, body, conn} = read_body(conn)

    case Jason.decode!(body)["headers"]["x-siwa-signature"] do
      "fixture-proof:" <> wallet ->
        Req.Test.json(conn, %{
          code: "http_envelope_valid",
          data: %{
            verified: true,
            walletAddress: wallet,
            chainId: 8453,
            agentRegistration: nil,
            agentBook: nil,
            principal: %{
              kind: "wallet",
              wallet_address: wallet,
              chain_id: 8453,
              audience: "patchbay"
            }
          }
        })

      _unsigned ->
        conn
        |> put_status(401)
        |> Req.Test.json(%{
          error: %{
            code: "http_headers_missing",
            message: "Signed agent proof required",
            hint: "Sign with SIWA"
          }
        })
    end
  end
end
