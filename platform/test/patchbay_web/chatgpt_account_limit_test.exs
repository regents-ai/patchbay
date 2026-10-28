defmodule PatchbayWeb.ChatGPTAccountLimitTest do
  @moduledoc """
  A connected account's share of identity and posting calls a minute at the
  ChatGPT address, counted before the hosted signer is asked to sign for it.
  Reads stay uncounted.
  """

  # It switches ChatGPT identities on and lowers the signed share for the
  # whole site while it runs.
  use PatchbayWeb.ConnCase, async: false

  import Plug.Conn

  alias Boruta.Ecto.Token
  alias Ecto.Adapters.SQL.Sandbox

  defmodule HostedSigner do
    @moduledoc "The hosted signer, saying each time it was asked and what for."
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(conn, test) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:hosted_signer_asked, Jason.decode!(body)["operation"]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{address: "0x" <> String.duplicate("a", 40)}))
    end
  end

  setup do
    signer =
      start_supervised!(
        {Bandit, plug: {HostedSigner, self()}, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(signer)

    put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "http://127.0.0.1:#{port}", key: String.duplicate("k", 32)]
    )

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

    put_env(:patchbay, :chatgpt_account_per_minute, 2)

    put_env(
      :regent_oauth,
      RegentOAuth.Repo,
      Keyword.put(Application.fetch_env!(:regent_oauth, RegentOAuth.Repo), :pool, Sandbox)
    )

    start_supervised!(RegentOAuth.Repo)
    :ok = Sandbox.checkout(RegentOAuth.Repo)
    Sandbox.mode(RegentOAuth.Repo, {:shared, self()})

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

    %{client: client}
  end

  test "an account's identity and posting calls past its share are refused without asking the hosted signer",
       %{conn: conn, client: client} do
    bearer = account!(client)

    first = call_tool(conn, bearer, "register_identity", %{})
    assert json_response(first, 200)["result"]["isError"] == false
    assert ratelimit(first) =~ ~s("signed";r=1;t=)
    assert_received {:hosted_signer_asked, "register"}

    second = call_tool(conn, bearer, "ask_question", question())
    assert json_response(second, 200)["result"]["isError"] == true
    assert ratelimit(second) =~ ~s("signed";r=0;t=)
    assert_received {:hosted_signer_asked, "sign"}

    refused = call_tool(conn, bearer, "pair_identity", %{"code" => "ABCD-1234", "name" => "Chat"})

    assert json_response(refused, 429) ==
             %{
               "error" => %{
                 "code" => "too_many_requests",
                 "message" => "Too Many Requests",
                 "hint" =>
                   "Wait the number of seconds in Retry-After, then send the request again."
               }
             }

    assert get_resp_header(refused, "ratelimit-policy") |> hd() =~ ~s("signed";q=2;w=60)
    assert ratelimit(refused) =~ ~s("signed";r=0;t=)
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60
    refute_received {:hosted_signer_asked, _operation}
  end

  test "another account keeps a share of its own", %{conn: conn, client: client} do
    spent = account!(client)

    for _call <- 1..2, do: call_tool(conn, spent, "register_identity", %{})
    assert call_tool(conn, spent, "register_identity", %{}).status == 429

    other = call_tool(conn, account!(client), "register_identity", %{})
    assert json_response(other, 200)["result"]["isError"] == false
    assert ratelimit(other) =~ ~s("signed";r=1;t=)
  end

  test "reads are not counted", %{conn: conn, client: client} do
    bearer = account!(client)

    for _read <- 1..3 do
      read = call_tool(conn, bearer, "search_threads", %{"q" => "booking"})
      assert json_response(read, 200)["result"]["isError"] == false
      refute ratelimit(read) =~ "signed"
    end

    for left <- [1, 0] do
      assert ratelimit(call_tool(conn, bearer, "register_identity", %{})) =~
               ~s("signed";r=#{left};t=)
    end

    assert call_tool(conn, bearer, "register_identity", %{}).status == 429
    assert json_response(call_tool(conn, bearer, "get_patchbay_help", %{}), 200)
  end

  # A Privy-signed-in person and a live access token for their account,
  # granting identity setup and posting.
  defp account!(client) do
    profile =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:chatgpt-#{System.unique_integer([:positive])}",
        wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      })

    RegentOAuth.Repo.insert!(%Token{
      type: "access_token",
      value: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      client_id: client.id,
      sub: profile.privy_user_id,
      scope: Enum.join([RegentMCPAgents.identity_scope(), RegentMCPAgents.posting_scope()], " "),
      expires_at: System.system_time(:second) + 3600
    }).value
  end

  defp question do
    %{
      "site" => "https://shop.example",
      "title" => "How do I change a booking here?",
      "body_markdown" => "The booking tool takes a date but I cannot find a way to move it.",
      "client_request_id" => Ecto.UUID.generate()
    }
  end

  defp call_tool(conn, bearer, name, arguments) do
    conn
    |> recycle()
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

  defp ratelimit(conn), do: conn |> get_resp_header("ratelimit") |> Enum.join(", ")

  defp put_env(app, key, value) do
    old = Application.fetch_env!(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> Application.put_env(app, key, old) end)
  end
end
