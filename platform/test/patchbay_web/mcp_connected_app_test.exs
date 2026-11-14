defmodule PatchbayWeb.MCPConnectedAppTest do
  @moduledoc """
  An app connected at patchbay.help's `/mcp`, such as a Claude connector
  (`PatchbayWeb.MCP.ConnectedApp`): it signs in by its published identity,
  pairs its own identity with the person's code, then asks, replies and reads
  back its post as that paired agent with its token alone, never a wallet
  signature, its answers carrying the thread's paid offers as a signed
  agent's do. Payments and every other signed tool stay with a wallet; ending
  the pairing, the connection or the person's standing ends its access; the
  open address's ChatGPT tools stay as they are.

  Only the sign-in service and Claude's published identity are stand-ins: the
  hosted signer keeps one wallet per identity and signs as it, and the SIWA
  check accepts that wallet's fixture proof (`PatchbayWeb.SignedAgent`).
  """

  # It switches both addresses' sign-in and the hosted identities on for the
  # whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  import PatchbayTest.OfferFixtures,
    only: [offers_on!: 0, placement!: 2, shown_campaign!: 1, lease!: 3, person!: 1, wallet: 0]

  alias Patchbay.Forum.Report
  alias PatchbayWeb.SignedAgent
  alias PatchbayWeb.SiteEdition

  @claude "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @claude_callback "https://claude.ai/api/mcp/auth_callback"
  @verifier String.duplicate("v", 43)
  @both "regent.identity.manage patchbay.posts.write"

  defmodule ClaudeDocument do
    @moduledoc "Claude's published identity, served without a network; each read is told to the test."
    @claude "https://claude.ai/oauth/mcp-oauth-client-metadata"

    def request(:get, @claude = url, _opts) do
      send(Application.fetch_env!(:patchbay, __MODULE__), {:read, url})

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "client_id" => @claude,
             "client_name" => "Claude",
             "client_uri" => "https://claude.ai",
             "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
             "grant_types" => ["authorization_code", "refresh_token"],
             "response_types" => ["code"],
             "token_endpoint_auth_method" => "none"
           })
       }}
    end
  end

  setup do
    SignedAgent.stub_siwa()
    test = self()

    put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "https://signer.test", key: String.duplicate("k", 32)]
    )

    put_env(:regent_mcp_agents, :req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, &signer(&1, test))

    Patchbay.OAuthSwitch.on(:open,
      additional_scopes: %{
        RegentMCPAgents.identity_scope() => "connect ChatGPT",
        RegentMCPAgents.posting_scope() => "post free questions and replies"
      }
    )

    Patchbay.OAuthSwitch.on(:main)
    put_env(:regent_agents, :hosted_pairing, [:chatgpt, :claude])
    :ok
  end

  test "Claude signs in by its published identity, pairs, then asks, replies and reads back its post without a signature",
       %{conn: conn} do
    put_env(:regent_http, :public_client, ClaudeDocument)
    put_env(:patchbay, ClaudeDocument, self())
    owner = account!()

    server = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert server["client_id_metadata_document_supported"] == true

    # Consent, as the person sees it, signed in here.
    page =
      conn
      |> sign_in(owner.id)
      |> put_req_header("accept", "text/html")
      |> get("/oauth/authorize?" <> authorize_query(@claude, @both))

    assert html_response(page, 200) =~ "Connect Claude"
    assert_received {:read, @claude}

    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)
    [_, key] = Regex.run(~r/name="approval_key" value="([^"]+)"/, page.resp_body)

    approved =
      page
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> post("/oauth/authorize", %{
        "_csrf_token" => csrf,
        "approval_key" => key,
        "decision" => "allow"
      })

    assert approved.status == 303
    [location] = get_resp_header(approved, "location")
    assert String.starts_with?(location, @claude_callback <> "?")
    code = URI.decode_query(URI.parse(location).query)["code"]

    %{"access_token" => token} =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => @claude,
        "code" => code,
        "code_verifier" => @verifier,
        "redirect_uri" => @claude_callback,
        "resource" => main(&RegentOAuth.resource/0)
      })
      |> json_response(200)

    # Only consent reads the published identity.
    refute_received {:read, @claude}

    names = conn |> rpc("tools/list", %{}, token) |> json_response(200)
    names = Enum.map(names["result"]["tools"], & &1["name"])
    assert ["register_identity", "pair_identity", "ask_question"] -- names == []

    assert %{"paired" => false} = structured(tool(conn, token, "get_identity"))

    # Not yet paired, a post is refused with what to do.
    assert refusal(tool(conn, token, "ask_question", question()))["code"] == "agent_not_paired"

    pair = %{"code" => code!(owner), "name" => "Claude", "harness" => "claude"}
    assert %{"paired" => true} = structured(tool(conn, token, "pair_identity", pair))
    assert [%{harness: :claude, name: "Claude"} = agent] = agents(owner)

    question = question()
    asked = structured(tool(conn, token, "ask_question", question))
    thread = Ash.get!(Report, asked["thread_id"], authorize?: false)
    assert thread.browser_session_id == agent.id

    reply = %{
      "thread_id" => thread.id,
      "body_markdown" => "Moving the date worked once I picked the booking first.",
      "client_request_id" => Ecto.UUID.generate()
    }

    assert is_binary(structured(tool(conn, token, "post_reply", reply))["reply_id"])

    status =
      structured(
        tool(conn, token, "get_request_status", %{
          "client_request_id" => question["client_request_id"]
        })
      )

    assert Jason.encode!(status) =~ thread.id

    # The hosted signer signed only the identity requests; no post was signed.
    signed = for {:signed, path} <- messages(), do: path
    assert signed != []
    assert signed -- ["/api/agents/v1/whoami", "/api/agents/v1/pair"] == []
  end

  test "a connected app's question and reply carry the thread's offers, as a signed agent's do",
       %{conn: conn} do
    offers_on!()
    Patchbay.Forum.register_site!("stripe.com")
    placement!(1, "stripe.com")
    campaign = shown_campaign!(person!(wallet()))
    lease!(1, 0, campaign)

    %{access: token} = paired!(conn, account!())

    asked =
      structured(tool(conn, token, "ask_question", Map.put(question(), "site", "stripe.com")))

    assert [%{"paid" => true, "placement_id" => 1, "campaign_id" => id}] =
             asked["paid_offers"]["offers"]

    assert id == campaign.campaign_id

    reply = %{
      "thread_id" => asked["thread_id"],
      "body_markdown" => "Same here.",
      "client_request_id" => Ecto.UUID.generate()
    }

    replied = structured(tool(conn, token, "post_reply", reply))
    assert replied["paid_offers"]["offers"] == asked["paid_offers"]["offers"]

    # One delivery at /mcp, read by the paired agent the app posted as.
    thread = Ash.get!(Report, asked["thread_id"], authorize?: false)

    assert [%{viewer_kind: :agent, surface: :mcp, viewer: viewer, context: context}] =
             Ash.read!(Patchbay.Offers.Delivery, actor: %{role: :system})

    assert viewer == thread.author_profile_id
    assert context == "/posts/" <> thread.id
  end

  test "a call a connection could make, sent with nothing, starts its sign-in; reads stay open",
       %{conn: conn} do
    challenge =
      ~s(Bearer resource_metadata="#{main(&RegentOAuth.issuer/0)}/.well-known/oauth-protected-resource", scope="#{@both}")

    for name <- ~w(ask_question post_reply get_request_status register_identity pair_identity) do
      refused = rpc(conn, "tools/call", %{"name" => name, "arguments" => %{}})
      assert refused.status == 401, name
      assert get_resp_header(refused, "www-authenticate") == [challenge]
      assert json_response(refused, 401)["error"]["data"]["code"] == "connection_required"
    end

    read = rpc(conn, "tools/call", %{"name" => "search_threads", "arguments" => %{"q" => "x"}})
    assert json_response(read, 200)["result"]["isError"] == false

    # A tool no connection may use still says how to sign.
    unsigned = rpc(conn, "tools/call", %{"name" => "follow_scope", "arguments" => %{}})
    assert refusal(unsigned)["code"] == "agent_auth_required"
  end

  test "a token that is not live is asked to sign in again, and one without posting is asked for it",
       %{conn: conn} do
    owner = account!()

    stale = rpc(conn, "tools/call", %{"name" => "get_identity"}, "not-a-token")
    assert stale.status == 401
    assert [header] = get_resp_header(stale, "www-authenticate")
    assert header =~ ~s(error="invalid_token")

    %{access: identity_only} = connect!(owner, RegentMCPAgents.identity_scope())
    assert %{"paired" => false} = structured(tool(conn, identity_only, "get_identity"))

    asked =
      rpc(
        conn,
        "tools/call",
        %{"name" => "ask_question", "arguments" => question()},
        identity_only
      )

    assert asked.status == 403
    assert [header] = get_resp_header(asked, "www-authenticate")
    assert header =~ ~s(scope="#{@both}", error="insufficient_scope")
  end

  test "payments stay with a wallet and every other signed tool with a signature", %{conn: conn} do
    owner = account!()
    %{access: token} = paired!(conn, owner)

    for name <- ~w(post_priority_report execute_payment get_payment_status) do
      assert refusal(tool(conn, token, name, %{}))["code"] == "wallet_only", name
    end

    for name <- ~w(follow_scope mark_solution like_post read_inbox get_updates) do
      assert refusal(tool(conn, token, name, %{}))["code"] == "not_in_connection", name
    end

    # A signature and a token together name two agents.
    agent = SignedAgent.pair!()

    both =
      conn
      |> recycle()
      |> SignedAgent.sign(agent)
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", call_body("ask_question", question()))

    assert refusal(both)["code"] == "ambiguous_credentials"
  end

  test "unpairing, disconnecting and suspension each end the app's access", %{conn: conn} do
    owner = account!()
    %{access: token} = paired!(conn, owner)
    assert structured(tool(conn, token, "ask_question", question()))["thread_id"]

    # Unpaired on the Agents page: it is refused until it pairs again.
    [agent] = agents(owner)
    :ok = RegentAgents.unpair_agent(agent, actor: person(owner))
    assert refusal(tool(conn, token, "ask_question", question()))["code"] == "agent_not_paired"

    # Disconnected: the token is no longer live, so the app is asked to sign in.
    other = paired!(conn, owner)
    assert {:ok, "Claude"} = Patchbay.OAuth.disconnect_app(owner.privy_user_id, other.client_id)

    assert {:error, :not_connected} =
             Patchbay.OAuth.disconnect_app(owner.privy_user_id, other.client_id)

    assert ask(conn, other.access).status == 401

    # Suspended: every token of theirs stops working.
    third = paired!(conn, owner)
    Patchbay.Identity.suspend_profile!(owner, "Spam", actor: %{role: :system})
    assert ask(conn, third.access).status == 401
  end

  test "an app's published identity at an internal address is never read", %{conn: conn} do
    owner = account!()

    # Apps are the sign-in library's own table, outside Ash.
    clients = Patchbay.Repo.aggregate(Boruta.Ecto.Client, :count)

    for client <-
          ~w(https://127.0.0.1/client.json https://localhost/client.json https://10.0.0.1/c) do
      page =
        conn
        |> sign_in(owner.id)
        |> put_req_header("accept", "text/html")
        |> get("/oauth/authorize?" <> authorize_query(client, @both))

      assert page.status == 400, client
      refute page.resp_body =~ "Connect", client
    end

    # No app was recorded: counted in the library's own table, outside Ash.
    assert Patchbay.Repo.aggregate(Boruta.Ecto.Client, :count) == clients
  end

  test "the open address's ChatGPT tools are unchanged with Claude connecting at patchbay.help",
       %{conn: conn} do
    tools =
      conn
      |> on_open()
      |> put_req_header("content-type", "application/json")
      |> post("/chatgpt/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    assert Enum.map(tools, & &1["name"]) ==
             ~w(search_threads get_thread get_patchbay_help get_tool_history
                read_site_directory render_repair_card register_identity get_identity
                pair_identity check_in ask_question post_reply)

    pair = Enum.find(tools, &(&1["name"] == "pair_identity"))
    assert pair["inputSchema"]["properties"]["harness"]["enum"] == ["chatgpt"]

    text = Jason.encode!(tools)
    refute text =~ ~r{//patchbay\.help}
    refute text =~ ~r/payment|wallet|bounty/i
  end

  # A person signed in through Privy, with the shared account a sign-in makes.
  defp account! do
    owner =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:claude-#{System.unique_integer([:positive])}",
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

  # An app connected to `owner`'s account at patchbay.help, as consent leaves
  # it, granted `scope`: its client id and the access token it holds.
  defp connect!(owner, scope \\ @both) do
    main(fn ->
      {:ok, client} =
        Boruta.Ecto.Admin.Clients.create_client(
          RegentOAuth.Protocol.public_client("Claude", [@claude_callback])
        )

      {:ok, token} =
        RegentOAuth.AccessTokens.create(
          %{
            client: Boruta.ClientsAdapter.get_client(client.id),
            sub: owner.privy_user_id,
            scope: scope
          },
          refresh_token: true
        )

      %{client_id: client.id, access: token.value}
    end)
  end

  # A new app of `owner`'s, connected and paired with a code of its own.
  defp paired!(conn, owner) do
    app = connect!(owner)
    pair = %{"code" => code!(owner), "name" => "Claude", "harness" => "claude"}
    assert %{"paired" => true} = structured(tool(conn, app.access, "pair_identity", pair))
    app
  end

  defp main(fun), do: SiteEdition.within(:main, fun)

  defp authorize_query(client_id, scope) do
    URI.encode_query(%{
      "client_id" => client_id,
      "redirect_uri" => @claude_callback,
      "response_type" => "code",
      "scope" => scope,
      "state" => "state",
      "resource" => main(&RegentOAuth.resource/0),
      "code_challenge" => :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
      "code_challenge_method" => "S256"
    })
  end

  defp question do
    %{
      "site" => "https://shop.example",
      "title" => "How do I change a booking here?",
      "body_markdown" => "The booking tool takes a date but I cannot find a way to move it.",
      "client_request_id" => Ecto.UUID.generate()
    }
  end

  defp code!(owner), do: RegentAgents.issue_pairing_code!(actor: person(owner)).code
  defp agents(owner), do: RegentAgents.list_my_agents!(actor: person(owner))
  defp person(owner), do: %RegentAgents.Person{privy_user_id: owner.privy_user_id}

  defp ask(conn, token),
    do: rpc(conn, "tools/call", %{"name" => "ask_question", "arguments" => question()}, token)

  defp tool(conn, token, name, arguments \\ %{}),
    do: conn |> rpc("tools/call", %{"name" => name, "arguments" => arguments}, token)

  defp rpc(conn, method, params, token \\ nil) do
    conn = conn |> recycle() |> put_req_header("content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end

  defp call_body(name, arguments),
    do:
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })

  defp structured(answer) do
    assert %{"isError" => false, "structuredContent" => content} =
             json_response(answer, 200)["result"]

    content
  end

  # A refusal is a tool result whose one text block is its JSON.
  defp refusal(answer) do
    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             json_response(answer, 200)["result"]

    Jason.decode!(text)["error"]
  end

  defp messages do
    receive do
      message -> [message | messages()]
    after
      0 -> []
    end
  end

  # The hosted signer keeps one wallet per identity key and signs as it, with
  # the proof `SignedAgent.stub_siwa/0` accepts.
  defp signer(%Plug.Conn{request_path: "/api/shared/siwa/hosted"} = conn, test) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    asked = Jason.decode!(body)
    wallet = "0x" <> binary_part(asked["identity_key"], 0, 40)

    case asked do
      %{"operation" => "register"} ->
        Req.Test.json(conn, %{"address" => wallet})

      %{"operation" => "sign", "request" => request} ->
        send(test, {:signed, request["path"]})
        headers = %{"x-siwa-signature" => "fixture-proof:" <> wallet}
        Req.Test.json(conn, Map.put(request, "headers", headers))
    end
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
