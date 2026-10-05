defmodule PatchbayWeb.ForumAPI.AgentOffersTest do
  # Agent Offers after a new post: each position is filled on its own from
  # the site's slot of that number or General's, only copy that may be shown
  # is returned, a repeated post carries none, and the forum result always
  # comes first.
  #
  # General's three slots are shared by every test, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures

  alias Patchbay.Forum
  alias Patchbay.Offers

  setup do
    origin = "offers-#{System.unique_integer([:positive])}.example"
    {:ok, site} = Forum.register_site(origin, authorize?: false)

    %{
      origin: origin,
      site: Offers.open_site_market!(site.id, authorize?: false),
      general: Offers.general_market!(),
      owner: advertiser()
    }
  end

  test "each position is the site's slot, else General's of the same number, never moved",
       %{conn: conn, origin: origin, site: site, general: general, owner: owner} do
    place(site, 3, approved_version(owner, "Site three", site))
    place(general, 1, approved_version(owner, "General one", general))
    place(general, 3, approved_version(owner, "General three", general))

    posted = ask(conn, origin)
    body = json_response(posted, 201)

    assert %{"items" => items} = offers = body["agent_offers"]
    assert offers["disclosure_version"] == "agent-offers-v1"
    assert offers["disclosure"] =~ "Eligible responses for #{origin}"

    assert Enum.map(items, &{&1["position"], &1["label"], &1["text"]}) == [
             {1, "General · Slot 1", "General one"},
             {3, "Site · Slot 3", "Site three"}
           ]

    # The forum result comes first, the Offers after it.
    {result_at, _} = :binary.match(posted.resp_body, ~s("thread_id"))
    {offers_at, _} = :binary.match(posted.resp_body, ~s("agent_offers"))
    assert result_at < offers_at

    delivery = Ash.get!(Offers.Delivery, offers["delivery_id"], authorize?: false)
    assert delivery.general_opportunities == [1, 2]
  end

  test "blocked, expired, stale or other-market copy is not shown, and General stands in",
       %{conn: conn, origin: origin, site: site, general: general, owner: owner} do
    {:ok, other_site} = Forum.register_site("elsewhere-offers.example", authorize?: false)
    other = Offers.open_site_market!(other_site.id, authorize?: false)

    blocked = approved_version(owner, "Blocked", site)
    place(site, 1, blocked)

    blocked
    |> Ash.Changeset.for_update(:block, %{reason: "misleading"})
    |> Ash.update!(authorize?: false)

    place(site, 2, approved_version(owner, "Ran out", site),
      starts_at: DateTime.add(DateTime.utc_now(), -73, :hour)
    )

    place(site, 3, approved_version(owner, "Suits another site", other))

    place(general, 1, approved_version(owner, "General one", general))

    place(
      general,
      2,
      approved_version(owner, "Stale", general,
        fresh_until: DateTime.add(DateTime.utc_now(), -1, :minute)
      )
    )

    place(general, 3, approved_version(owner, "General three", general))

    items = conn |> ask(origin) |> json_response(201) |> get_in(["agent_offers", "items"])

    assert Enum.map(items, &{&1["label"], &1["text"]}) == [
             {"General · Slot 1", "General one"},
             {"General · Slot 3", "General three"}
           ]
  end

  test "a post with nothing showing has no Offers section, and a repeat never has one",
       %{conn: conn, origin: origin, general: general, owner: owner} do
    first = ask(conn, origin, %{"client_request_id" => "same-question"})
    refute Map.has_key?(json_response(first, 201), "agent_offers")

    place(general, 2, approved_version(owner, "General two", general))

    repeated = ask(first, origin, %{"client_request_id" => "same-question"})
    body = json_response(repeated, 200)
    assert body["repeated"] == true
    refute Map.has_key?(body, "agent_offers")

    replied =
      repeated
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/forum/threads/#{body["thread_id"]}/replies",
        Jason.encode!(%{"body_markdown" => "Here is what worked for me."})
      )

    assert [%{"label" => "General · Slot 2"}] =
             replied |> json_response(201) |> get_in(["agent_offers", "items"])
  end

  @tag :capture_log
  test "a failure choosing Offers leaves them out and changes nothing else" do
    assert Offers.Serving.after_post(%{
             site_id: Ecto.UUID.generate(),
             report_id: Ecto.UUID.generate(),
             reply_id: nil,
             operation: :thread,
             surface: :http_api
           }) == nil
  end

  describe "hosted MCP" do
    test "a new post at /mcp carries Offers once, as their own block after the result",
         %{conn: conn, origin: origin, general: general, owner: owner} do
      place(general, 1, approved_version(owner, "General one", general))
      session = mcp_session(conn, "/mcp")

      result = mcp_ask(conn, "/mcp", session, origin)

      assert [%{"text" => posted}, %{"text" => offers}] = result["content"]
      assert %{"thread_id" => _} = Jason.decode!(posted)
      refute posted =~ "General one"

      assert offers =~ "Third-party Agent Offers — paid advertisements\n"
      assert offers =~ ~s(General · Slot 1 \(until )
      assert offers =~ ~s("General one")

      assert %{"items" => [%{"label" => "General · Slot 1"}]} =
               result["structuredContent"]["agent_offers"]
    end

    test "the ChatGPT plugin's address posts the same way and never carries Offers",
         %{conn: conn, origin: origin, general: general, owner: owner} do
      place(general, 1, approved_version(owner, "General one", general))
      session = mcp_session(conn, "/chatgpt/mcp")

      response = mcp_rpc(conn, "/chatgpt/mcp", session, "tools/call", ask_tool(origin))
      refute response.resp_body =~ "General one"
      refute response.resp_body =~ "agent_offers"

      assert %{"result" => %{"content" => [_only], "structuredContent" => %{"thread_id" => _}}} =
               json_response(response, 200)

      assert Ash.read!(Offers.Delivery, authorize?: false) == []
    end

    test "a session works only at the address it was issued at", %{conn: conn} do
      chatgpt = mcp_session(conn, "/chatgpt/mcp")
      native = mcp_session(conn, "/mcp")

      assert json_response(mcp_rpc(conn, "/mcp", chatgpt, "ping", %{}), 404)
      assert json_response(mcp_rpc(conn, "/chatgpt/mcp", native, "ping", %{}), 404)
      assert json_response(mcp_rpc(conn, "/chatgpt/mcp", chatgpt, "ping", %{}), 200)
    end
  end

  defp mcp_session(conn, path) do
    response = mcp_rpc(conn, path, nil, "initialize", %{"protocolVersion" => "2025-06-18"})
    [session] = get_resp_header(response, "mcp-session-id")
    session
  end

  defp mcp_ask(conn, path, session, origin) do
    %{"result" => result} =
      conn |> mcp_rpc(path, session, "tools/call", ask_tool(origin)) |> json_response(200)

    result
  end

  defp ask_tool(origin) do
    %{
      "name" => "ask_question",
      "arguments" => %{
        "site" => origin,
        "title" => "How do I change a booking here?",
        "body_markdown" => "The booking tool takes a date but I cannot find a way to move it."
      }
    }
  end

  defp mcp_rpc(conn, path, session, method, params) do
    conn = conn |> recycle() |> put_req_header("content-type", "application/json")
    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    post(conn, path, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end

  defp ask(conn, origin, extra \\ %{}) do
    conn
    |> recycle()
    |> get("/")
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/forum/threads",
      Jason.encode!(
        Map.merge(
          %{
            "site" => origin,
            "title" => "How do I change a booking here?",
            "body_markdown" => "The booking tool takes a date but I cannot find a way to move it."
          },
          extra
        )
      )
    )
  end
end
