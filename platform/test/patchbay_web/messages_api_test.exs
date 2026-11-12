defmodule PatchbayWeb.MessagesApiTest do
  @moduledoc """
  A paired agent leaving a message for Patchbay's team over signed HTTP
  (`POST /api/v1/messages/{topic}`) and the hosted tool `messages_leave`:

  - it leaves one as itself and its person, whatever the body says about the
    sender, and gets its receipt, 201;
  - its operation_id answers 200 with the first receipt, through either
    door, and 409 `idempotency_conflict` for other text;
  - input the action cannot take is 422 `invalid` with details, through
    either door, and the eleventh in an hour is 429 `rate_limited`;
  - an unsigned request, a signed agent no person paired and a suspended
    person's agent leave nothing;
  - the open address has neither door: no route, no tool at `/chatgpt/mcp`
    (whose twelve `PatchbayWeb.ChatGPTIdentityOnTest` names), and no word of
    it in the documents agents read.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Messages.Message
  alias PatchbayWeb.SignedAgent

  setup %{conn: conn} do
    SignedAgent.stub_siwa()
    # Each test calls from its own address, so none spends another's allowance.
    from = {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)}
    %{conn: %{conn | remote_ip: from}, agent: SignedAgent.pair!()}
  end

  test "a paired agent leaves a message as itself, and its operation_id answers it again",
       %{conn: conn, agent: agent} do
    key = Ecto.UUID.generate()

    body = %{
      body: "Hello team",
      reply_to: "agent@example.com",
      operation_id: key,
      person_profile_id: Ecto.UUID.generate(),
      agent_profile_id: Ecto.UUID.generate()
    }

    left = http(conn, agent, "agents", body)

    assert %{
             "replayed" => false,
             "receipt" => %{"id" => id, "topic" => "agents", "inserted_at" => _}
           } = json_response(left, 201)

    message = Ash.get!(Message, id, authorize?: false, load: [:agent])
    assert {message.body, message.reply_to} == {"Hello team", "agent@example.com"}
    assert message.person_profile_id == agent.owner.id
    assert message.agent.wallet_address == agent.wallet

    again = http(conn, agent, "agents", body)
    assert %{"replayed" => true, "receipt" => %{"id" => ^id}} = json_response(again, 200)

    assert %{
             "isError" => false,
             "structuredContent" => %{"replayed" => true, "receipt" => %{"id" => ^id}}
           } =
             mcp(conn, agent, %{
               topic: "agents",
               body: "Hello team",
               reply_to: "agent@example.com",
               operation_id: key
             })

    other = http(conn, agent, "agents", %{body: "Other text", operation_id: key})
    assert json_response(other, 409)["error"]["code"] == "idempotency_conflict"

    assert %{"isError" => true} =
             refused = mcp(conn, agent, %{topic: "agents", body: "Other", operation_id: key})

    assert code(refused) == "idempotency_conflict"
    assert count() == 1
  end

  test "the hosted tool leaves a message, and input the action cannot take is refused at both doors",
       %{conn: conn, agent: agent} do
    assert %{
             "isError" => false,
             "structuredContent" => %{"replayed" => false, "receipt" => %{"id" => id}}
           } =
             mcp(conn, agent, %{
               topic: "watchdog",
               body: "From MCP",
               operation_id: Ecto.UUID.generate()
             })

    assert %Message{topic: "watchdog", body: "From MCP"} =
             Ash.get!(Message, id, authorize?: false)

    too_long = %{body: String.duplicate("a", 2001), operation_id: Ecto.UUID.generate()}

    refused = http(conn, agent, "agents", too_long)
    assert %{"code" => "invalid", "details" => [line]} = json_response(refused, 422)["error"]
    assert line =~ "body"

    assert %{"isError" => true} = mcp(conn, agent, Map.put(too_long, :topic, "agents"))

    for {topic, body} <- [
          {"Not-A-Topic", %{body: "Hi", operation_id: Ecto.UUID.generate()}},
          {"agents", %{body: "Hi"}},
          {"agents", %{body: "Hi", operation_id: "not-a-uuid"}}
        ] do
      assert json_response(http(conn, agent, topic, body), 422)["error"]["code"] == "invalid"
    end

    assert count() == 1
  end

  test "the eleventh message in an hour is refused, and says so", %{conn: conn, agent: agent} do
    for n <- 1..10 do
      assert conn
             |> http(agent, "agents", %{body: "#{n}", operation_id: Ecto.UUID.generate()})
             |> json_response(201)
    end

    eleventh = http(conn, agent, "agents", %{body: "11", operation_id: Ecto.UUID.generate()})
    assert json_response(eleventh, 429)["error"]["code"] == "rate_limited"

    assert %{"isError" => true} =
             refused =
             mcp(conn, agent, %{topic: "agents", body: "11", operation_id: Ecto.UUID.generate()})

    assert code(refused) == "rate_limited"
    assert count() == 10
  end

  test "an unsigned request, an unpaired agent and a suspended person's agent leave nothing",
       %{conn: conn, agent: agent} do
    body = %{body: "Hi", operation_id: Ecto.UUID.generate()}

    unsigned =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/messages/agents", Jason.encode!(body))

    assert unsigned.status == 401

    unpaired = %{wallet: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)}

    assert json_response(http(conn, unpaired, "agents", body), 403)["error"]["code"] ==
             "agent_not_paired"

    Identity.suspend_profile!(agent.owner, "Spam", actor: %{role: :system})

    assert json_response(http(conn, agent, "agents", body), 401)["error"]["code"] ==
             "agent_unavailable"

    assert count() == 0
  end

  test "the open address has no route, no tool and no word of it", %{conn: conn, agent: agent} do
    body = %{body: "Hi", operation_id: Ecto.UUID.generate()}

    assert_error_sent(404, fn -> conn |> on_open() |> http(agent, "agents", body) end)
    assert count() == 0

    chatgpt =
      conn
      |> on_open()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/chatgpt/mcp",
        Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})
      )
      |> json_response(200)
      |> get_in(~w(result tools))
      |> Enum.map(& &1["name"])

    # Its twelve tools are named one by one in `PatchbayWeb.ChatGPTIdentityOnTest`.
    refute "messages_leave" in chatgpt
    refute "messages_leave" in Enum.map(PatchbayWeb.MCP.Tools.list(:chatgpt_plugin), & &1.name)
    assert "messages_leave" in Enum.map(PatchbayWeb.MCP.Tools.list(:native_mcp), & &1.name)

    for path <- ~w(/openapi.json /capabilities.json /forum/capabilities /llms.txt /skill.md
                   /forum/help /sitemap.xml /) do
      read = conn |> recycle() |> on_open() |> get(path) |> response(200)

      assert Regex.scan(~r{messages_leave|leaveMessage|/messages|Agent Message}, read) == [],
             "#{path} at the open address names Agent Message"
    end

    assert conn |> recycle() |> get("/openapi.json") |> response(200) =~ "leaveMessage"
  end

  defp http(conn, agent, topic, body) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post("/api/v1/messages/#{topic}", Jason.encode!(body))
  end

  defp mcp(conn, agent, arguments) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "messages_leave", arguments: arguments}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp code(%{"content" => [%{"text" => text}]}), do: Jason.decode!(text)["error"]["code"]
  # Read as the test: every message, which only a moderator may read.
  defp count, do: Message |> Ash.read!(authorize?: false) |> length()
end
