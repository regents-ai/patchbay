defmodule PatchbayWeb.ChatGPTAppIdentityTest do
  @moduledoc """
  Each app a person connects at the ChatGPT address has an identity of its
  own: an app is the agent it paired with its own code, never one the same
  account paired through another app, and a refreshed token is still the same
  app.
  """

  # It switches ChatGPT identities on for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.Report
  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()

    put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "https://signer.test", key: String.duplicate("k", 32)]
    )

    put_env(:regent_mcp_agents, :req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, &outside/1)

    put_env(
      :patchbay,
      Patchbay.OAuth,
      Keyword.merge(Application.fetch_env!(:patchbay, Patchbay.OAuth),
        enabled?: true,
        additional_scopes: %{
          RegentMCPAgents.identity_scope() => "connect ChatGPT",
          RegentMCPAgents.posting_scope() => "post free questions and replies"
        }
      )
    )

    put_env(:regent_agents, :hosted_pairing, [:chatgpt])

    :ok
  end

  test "a second app of an account already paired through another app posts nothing until it pairs with its own code",
       %{conn: conn} do
    owner = account!()
    first = connect!(conn, owner)
    pair!(conn, first, owner)

    assert paired?(conn, first)
    first_thread = ask!(conn, first)

    second = connect!(conn, owner)
    refute paired?(conn, second)

    refused = call_tool(conn, second.access, "ask_question", question())
    assert %{"isError" => true, "content" => [%{"text" => text}]} = refused
    assert Jason.decode!(text)["error"]["code"] == "agent_not_paired"
    assert length(agents(owner)) == 1

    # Paired with a code of its own, it is a second agent, posting as itself.
    pair!(conn, second, owner)

    assert paired?(conn, second)
    second_thread = ask!(conn, second)

    refute pairing(second_thread) == pairing(first_thread)
    assert length(agents(owner)) == 2
  end

  test "a refreshed token keeps its app's identity and its pairing", %{conn: conn} do
    owner = account!()
    first = connect!(conn, owner)
    pair!(conn, first, owner)
    before = ask!(conn, first)

    refreshed = refresh!(conn, first)
    refute refreshed.access == first.access

    assert identity(conn, refreshed) == identity(conn, first)
    assert paired?(conn, refreshed)
    assert pairing(ask!(conn, refreshed)) == pairing(before)
    assert length(agents(owner)) == 1
  end

  # A person signed in through Privy, with the shared account a sign-in makes.
  defp account! do
    owner =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:app-#{System.unique_integer([:positive])}",
        wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      })

    now = System.system_time(:second)

    {:ok, _account} =
      Patchbay.Accounts.establish(%RegentPrivy.Session{
        app_id: "test-app",
        session_id: "test-session",
        privy_user_id: owner.privy_user_id,
        wallet_address: owner.wallet_address,
        wallet_addresses: [owner.wallet_address],
        issued_at: now,
        expires_at: now + 600
      })

    owner
  end

  # An app registered at the site's own registration address and connected to
  # `owner`'s account: its client id and the plain access and refresh tokens
  # it holds.
  defp connect!(conn, owner) do
    client_id =
      conn
      |> recycle()
      |> on_open()
      |> post("/oauth/register", %{
        "client_name" => "ChatGPT",
        "redirect_uris" => ["https://chatgpt.com/connector/oauth/callback"]
      })
      |> json_response(201)
      |> Map.fetch!("client_id")

    {:ok, token} =
      RegentOAuth.AccessTokens.create(
        %{
          client: Boruta.ClientsAdapter.get_client(client_id),
          sub: owner.privy_user_id,
          scope:
            Enum.join([RegentMCPAgents.identity_scope(), RegentMCPAgents.posting_scope()], " ")
        },
        refresh_token: true
      )

    %{client_id: client_id, access: token.value, refresh: token.refresh_token}
  end

  defp refresh!(conn, app) do
    answer =
      conn
      |> recycle()
      |> on_open()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => app.client_id,
        "refresh_token" => app.refresh,
        "resource" => RegentOAuth.resource()
      })
      |> json_response(200)

    %{app | access: answer["access_token"], refresh: answer["refresh_token"]}
  end

  defp pair!(conn, app, owner) do
    code = RegentAgents.issue_pairing_code!(actor: person(owner)).code
    arguments = %{"code" => code, "name" => "ChatGPT", "harness" => "chatgpt"}
    assert %{"isError" => false} = call_tool(conn, app.access, "pair_identity", arguments)
  end

  defp paired?(conn, app) do
    assert %{"isError" => false, "structuredContent" => %{"paired" => paired}} =
             call_tool(conn, app.access, "get_identity", %{})

    paired
  end

  defp identity(conn, app) do
    assert %{"isError" => false, "structuredContent" => %{"identity_id" => id}} =
             call_tool(conn, app.access, "register_identity", %{})

    id
  end

  # Asks a free question as `app`'s agent and answers the thread it filed.
  defp ask!(conn, app) do
    assert %{"isError" => false, "structuredContent" => %{"thread_id" => thread_id}} =
             call_tool(conn, app.access, "ask_question", question())

    thread_id
  end

  # The pairing a thread stands under: the agent that asked it.
  defp pairing(thread_id), do: Ash.get!(Report, thread_id).browser_session_id

  defp agents(owner), do: RegentAgents.list_my_agents!(actor: person(owner))

  defp person(owner), do: %RegentAgents.Person{privy_user_id: owner.privy_user_id}

  defp question do
    %{
      "site" => "quiet.example.net",
      "title" => "Can this site amend a reservation?",
      "body_markdown" => "I found create_reservation but nothing to amend one.",
      "client_request_id" => Ecto.UUID.generate()
    }
  end

  defp call_tool(conn, bearer, name, arguments) do
    conn
    |> recycle()
    |> on_open()
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/chatgpt/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  # What the site reaches outside itself for a connected app. The hosted
  # signer keeps one wallet per identity key and signs as it, with the proof
  # `SignedAgent.stub_siwa/0` accepts; a post goes to the site's own signed
  # posting address, at the open host the test site answers on.
  defp outside(%Plug.Conn{request_path: "/api/shared/siwa/hosted"} = conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    asked = Jason.decode!(body)
    wallet = "0x" <> binary_part(asked["identity_key"], 0, 40)

    case asked do
      %{"operation" => "register"} ->
        Req.Test.json(conn, %{"address" => wallet})

      %{"operation" => "sign", "request" => request} ->
        headers = %{"x-siwa-signature" => "fixture-proof:" <> wallet}
        Req.Test.json(conn, Map.put(request, "headers", headers))
    end
  end

  # The post arrives as a request from outside does: its exact bytes, unread.
  defp outside(%Plug.Conn{request_path: "/chatgpt/agent/mcp"} = conn) do
    answer =
      Plug.Test.conn(:post, "/chatgpt/agent/mcp", IO.iodata_to_binary(Req.Test.raw_body(conn)))
      |> Map.replace!(:req_headers, conn.req_headers)
      |> on_open()
      |> PatchbayWeb.Endpoint.call([])

    conn
    |> Plug.Conn.merge_resp_headers(answer.resp_headers)
    |> Plug.Conn.send_resp(answer.status, answer.resp_body)
  end

  defp put_env(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case old do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
