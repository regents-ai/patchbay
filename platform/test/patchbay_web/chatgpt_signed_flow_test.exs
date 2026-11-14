defmodule PatchbayWeb.ChatGPTSignedFlowTest do
  @moduledoc """
  One ChatGPT account from connection to its first post, through the ChatGPT
  address: register its identity, read it unpaired, pair it with the person's
  own one-use code, read it paired, check in, ask a question and reply to it.

  Only the sign-in service is a stand-in: the hosted signer signs each request
  as the account's one wallet, and the SIWA check accepts that wallet's fixture
  proof (`PatchbayWeb.SignedAgent`). Every Patchbay step is real: the access
  token, the identity tools, the in-process identity requests, the signed post
  sent over HTTP to the ChatGPT posting address, its pairing check and the
  forum write.
  """

  # It switches ChatGPT identities on for the whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn
  import PatchbayTest.OfferFixtures

  alias Boruta.Ecto.Token
  alias Patchbay.Forum.Report
  alias PatchbayWeb.SignedAgent

  setup do
    SignedAgent.stub_siwa()
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    test = self()

    put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "https://signer.test", key: String.duplicate("k", 32)]
    )

    # The signer's address answers as the hosted signer; the site's own
    # address is this site, at its open host.
    put_env(:regent_mcp_agents, :req_options, plug: &route(&1, wallet, test))

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

    {:ok, client} =
      Boruta.Ecto.Admin.Clients.create_client(%{
        name: "ChatGPT",
        redirect_uris: ["https://chatgpt.com/connector/oauth/callback"],
        confidential: false,
        pkce: true,
        supported_grant_types: ["authorization_code", "refresh_token", "revoke"],
        access_token_ttl: 3600,
        authorization_code_ttl: 60,
        refresh_token_ttl: 2_592_000
      })

    %{client: client, wallet: wallet}
  end

  test "an account registers, pairs with its own code, checks in, asks and replies",
       %{conn: conn, client: client, wallet: wallet} do
    {person, bearer} = account!(client)

    registered = structured(call_tool(conn, bearer, "register_identity", %{}))
    assert registered["account_url"] =~ "/account/agents"
    assert_received {:hosted_signer_asked, "register"}

    assert %{"paired" => false} = structured(call_tool(conn, bearer, "get_identity", %{}))

    code = RegentAgents.issue_pairing_code!(actor: person)

    paired =
      call_tool(conn, bearer, "pair_identity", %{
        "code" => code.code,
        "name" => "ChatGPT",
        "harness" => "chatgpt"
      })

    assert %{"paired" => true, "name" => "ChatGPT"} = structured(paired)
    assert %{"paired" => true} = structured(call_tool(conn, bearer, "get_identity", %{}))

    pairing = Ash.read_one!(RegentAgents.PairedAgent, authorize?: false)
    assert pairing.wallet == wallet
    assert pairing.harness == :chatgpt

    assert structured(call_tool(conn, bearer, "check_in", %{}))["identity_id"] ==
             registered["identity_id"]

    # A live offer in General, which any site's thread would show at /mcp:
    # the ChatGPT address carries none and records no delivery.
    offers_on!()
    placement!(9, "general")
    lease!(9, 0, shown_campaign!(person!(wallet())))

    asked =
      structured(
        call_tool(conn, bearer, "ask_question", %{
          "site" => "https://shop.example",
          "title" => "How do I change a booking here?",
          "body_markdown" => "The booking tool takes a date but I cannot find a way to move it.",
          "client_request_id" => Ecto.UUID.generate()
        })
      )

    thread = Ash.get!(Report, asked["thread_id"], authorize?: false)
    assert thread.browser_session_id == pairing.id

    replied =
      structured(
        call_tool(conn, bearer, "post_reply", %{
          "thread_id" => thread.id,
          "body_markdown" => "Moving the date worked once I picked the booking first.",
          "client_request_id" => Ecto.UUID.generate()
        })
      )

    assert is_binary(replied["reply_id"])
    assert_received {:hosted_signer_asked, "sign"}

    refute Map.has_key?(asked, "paid_offers")
    refute Map.has_key?(replied, "paid_offers")
    assert Ash.read!(Patchbay.Offers.Delivery, actor: %{role: :system}) == []
  end

  # The hosted signer registers the account's one wallet and signs each
  # request it is given as that wallet; any other address is this site.
  defp route(%{request_path: "/api/shared/siwa/hosted"} = conn, wallet, test) do
    {:ok, body, conn} = read_body(conn)
    asked = Jason.decode!(body)
    send(test, {:hosted_signer_asked, asked["operation"]})

    answer =
      case asked do
        %{"operation" => "register"} ->
          %{address: wallet}

        %{"operation" => "sign", "request" => request} ->
          request
          |> Map.take(["method", "path", "body"])
          |> Map.put("headers", %{"X-SIWA-Signature" => "fixture-proof:" <> wallet})
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(answer))
  end

  # Req has already parsed the body it hands a plug, so the site is given the
  # request as it would arrive over the network: its exact bytes and headers,
  # at the open host. Its answer is passed back unchanged.
  defp route(conn, _wallet, _test) do
    answer =
      conn.method
      |> Plug.Test.conn(
        "http://#{PatchbayWeb.SiteEdition.open_host()}#{conn.request_path}",
        Req.Test.raw_body(conn)
      )
      |> Map.replace!(:req_headers, conn.req_headers)
      |> PatchbayWeb.Endpoint.call(PatchbayWeb.Endpoint.init([]))

    %{conn | resp_headers: answer.resp_headers}
    |> send_resp(answer.status, answer.resp_body)
  end

  # A Privy-signed-in person with a shared account, and a live access token
  # for that account granting identity setup and posting.
  defp account!(client) do
    profile =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:chatgpt-#{System.unique_integer([:positive])}",
        wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      })

    now = System.system_time(:second)

    {:ok, _account} =
      Patchbay.Accounts.establish(%RegentPrivy.Session{
        app_id: "test-app",
        session_id: "test-session",
        privy_user_id: profile.privy_user_id,
        wallet_address: profile.wallet_address,
        wallet_addresses: [profile.wallet_address],
        issued_at: now,
        expires_at: now + 600
      })

    bearer = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    token =
      Patchbay.Repo.insert!(%Token{
        type: "access_token",
        value: RegentOAuth.hash_token(bearer),
        client_id: client.id,
        sub: profile.privy_user_id,
        scope:
          Enum.join([RegentMCPAgents.identity_scope(), RegentMCPAgents.posting_scope()], " "),
        expires_at: System.system_time(:second) + 3600
      })

    :ok = RegentOAuth.bind(token.id)
    {%RegentAgents.Person{privy_user_id: profile.privy_user_id}, bearer}
  end

  defp structured(conn) do
    assert %{"isError" => false, "structuredContent" => content} =
             json_response(conn, 200)["result"]

    content
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
