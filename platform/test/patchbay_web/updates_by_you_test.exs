defmodule PatchbayWeb.UpdatesByYouTest do
  @moduledoc """
  Whose doing an update is. A and B are two agents paired to one person, C an
  agent paired to someone else. `by_you` is true only for what the reader
  wrote itself, never for what another agent of the same person wrote, and
  every event names its author by public profile id. The same holds on the
  feed over HTTP, through `get_updates` at `/mcp` and on a webhook delivery,
  and for the person's own connected app, whose subscription reads as the
  person: their own post is theirs, their agent's is not.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  alias Boruta.Ecto.Token
  alias Patchbay.Forum.EventSubscription
  alias PatchbayWeb.OpenAPIShape
  alias PatchbayWeb.SignedAgent

  setup %{conn: conn} do
    SignedAgent.stub_siwa()
    a = SignedAgent.pair!()
    b = SignedAgent.pair!(a.owner)
    c = SignedAgent.pair!()
    thread_id = ask!(conn, a)

    %{a: a, b: b, c: c, thread_id: thread_id}
  end

  test "over HTTP, only the reader's own writing is by_you", %{
    conn: conn,
    a: a,
    b: b,
    c: c,
    thread_id: thread_id
  } do
    %{"reply_id" => from_b} = reply!(conn, b, thread_id)
    %{"reply_id" => from_c} = reply!(conn, c, thread_id)
    %{"reply_id" => from_a} = reply!(conn, a, thread_id)
    from_patchbay = patchbay_reply!(thread_id)
    mark!(conn, a, thread_id, from_c)

    for_a = feed(conn, a, thread_id)
    for_b = feed(conn, b, thread_id)

    assert by_you(for_a) == %{
             {"thread_posted", thread_id} => true,
             {"reply_posted", from_b} => false,
             {"reply_posted", from_c} => false,
             {"reply_posted", from_a} => true,
             {"reply_posted", from_patchbay} => false,
             {"solution_marked", from_c} => true
           }

    assert by_you(for_b) == %{
             {"thread_posted", thread_id} => false,
             {"reply_posted", from_b} => true,
             {"reply_posted", from_c} => false,
             {"reply_posted", from_a} => false,
             {"reply_posted", from_patchbay} => false,
             {"solution_marked", from_c} => false
           }

    # Patchbay's own reply was written by nobody signed in.
    authors = %{
      {"thread_posted", thread_id} => public_id(a),
      {"reply_posted", from_b} => public_id(b),
      {"reply_posted", from_c} => public_id(c),
      {"reply_posted", from_a} => public_id(a),
      {"reply_posted", from_patchbay} => nil,
      {"solution_marked", from_c} => public_id(a)
    }

    assert authors(for_a) == authors
    assert authors(for_b) == authors

    # The answer is the shape openapi.json gives it, a null author included.
    spec = conn |> recycle() |> get("/openapi.json") |> json_response(200)

    schema =
      get_in(spec, [
        "paths",
        "/forum/updates",
        "post",
        "responses",
        "200",
        "content",
        "application/json",
        "schema"
      ])

    OpenAPIShape.assert_shape(spec, schema, for_a)
  end

  test "through get_updates at /mcp, only the reader's own writing is by_you", %{
    conn: conn,
    a: a,
    b: b,
    c: c,
    thread_id: thread_id
  } do
    %{"reply_id" => from_b} = reply!(conn, b, thread_id)
    %{"reply_id" => from_c} = reply!(conn, c, thread_id)
    %{"reply_id" => from_a} = reply!(conn, a, thread_id)

    for_a = hosted_feed(conn, a, thread_id)
    for_b = hosted_feed(conn, b, thread_id)

    assert by_you(for_a) == %{
             {"thread_posted", thread_id} => true,
             {"reply_posted", from_b} => false,
             {"reply_posted", from_c} => false,
             {"reply_posted", from_a} => true
           }

    assert by_you(for_b) == %{
             {"thread_posted", thread_id} => false,
             {"reply_posted", from_b} => true,
             {"reply_posted", from_c} => false,
             {"reply_posted", from_a} => false
           }

    assert authors(for_a) == %{
             {"thread_posted", thread_id} => public_id(a),
             {"reply_posted", from_b} => public_id(b),
             {"reply_posted", from_c} => public_id(c),
             {"reply_posted", from_a} => public_id(a)
           }
  end

  test "on a webhook, each subscriber's own writing is by_you, and no other agent's", %{
    conn: conn,
    a: a,
    b: b,
    c: c,
    thread_id: thread_id
  } do
    subscribe!(conn, a, thread_id, "reply_created", "https://echo.test/a")
    subscribe!(conn, b, thread_id, "reply_created", "https://echo.test/b")
    subscribe!(conn, a, thread_id, "solution_marked", "https://echo.test/a-solutions")
    subscribe!(conn, b, thread_id, "solution_marked", "https://echo.test/b-solutions")
    Oban.drain_queue(queue: :webhooks)

    %{"reply_id" => from_b} = reply!(conn, b, thread_id)
    %{"reply_id" => from_c} = reply!(conn, c, thread_id)
    %{"reply_id" => from_a} = reply!(conn, a, thread_id)
    mark!(conn, a, thread_id, from_c)
    AshOban.Test.schedule_and_run_triggers({EventSubscription, :deliver})

    deliveries = delivered()

    assert by_you(deliveries, "https://echo.test/a") == %{
             from_b => false,
             from_c => false,
             from_a => true
           }

    assert by_you(deliveries, "https://echo.test/b") == %{
             from_b => true,
             from_c => false,
             from_a => false
           }

    assert by_you(deliveries, "https://echo.test/a-solutions") == %{from_c => true}
    assert by_you(deliveries, "https://echo.test/b-solutions") == %{from_c => false}

    assert authors(deliveries, "https://echo.test/a") == %{
             from_b => public_id(b),
             from_c => public_id(c),
             from_a => public_id(a)
           }

    assert authors(deliveries, "https://echo.test/b-solutions") == %{from_c => public_id(a)}

    # Each delivery is named for its subscription and event, so a receiver
    # drops a repeat by eventId.
    ids = for {_url, envelope} <- deliveries, do: envelope["eventId"]
    assert length(Enum.uniq(ids)) == length(deliveries)
  end

  test "the person's own connected app reads their own post as theirs and their agent's as not",
       %{conn: conn, a: a, thread_id: thread_id} do
    person = a.owner
    Patchbay.OAuthSwitch.on(:open)
    bearer = connect!(person)

    assert %{"result" => %{"id" => "sub_" <> _}} =
             conn
             |> recycle()
             |> on_open()
             |> put_req_header("authorization", "Bearer " <> bearer)
             |> put_req_header("content-type", "application/json")
             |> post(
               "/chatgpt/mcp",
               rpc(
                 "events/subscribe",
                 subscription(thread_id, "reply_created", "https://echo.test/person")
               )
             )
             |> json_response(200)

    Oban.drain_queue(queue: :webhooks)

    own =
      Patchbay.Forum.post_human_reply!(
        %{
          report_id: thread_id,
          browser_session_id: Ash.UUID.generate(),
          body_markdown: "Signed in on the page, I tried amend_reservation myself."
        },
        actor: person
      )

    %{"reply_id" => from_a} = reply!(conn, a, thread_id)
    AshOban.Test.schedule_and_run_triggers({EventSubscription, :deliver})

    deliveries = delivered()

    assert by_you(deliveries, "https://echo.test/person") == %{own.id => true, from_a => false}

    assert authors(deliveries, "https://echo.test/person") == %{
             own.id => person.public_id,
             from_a => public_id(a)
           }
  end

  # Each event's by_you, by its kind and what it is about.
  defp by_you(%{"events" => events}),
    do: Map.new(events, &{{&1["kind"], &1["resource_id"]}, &1["by_you"]})

  defp by_you(deliveries, url),
    do:
      for(
        {^url, envelope} <- deliveries,
        into: %{},
        do: {envelope["data"]["reply_id"], envelope["data"]["by_you"]}
      )

  defp authors(%{"events" => events}),
    do: Map.new(events, &{{&1["kind"], &1["resource_id"]}, &1["author_profile_id"]})

  defp authors(deliveries, url),
    do:
      for(
        {^url, envelope} <- deliveries,
        into: %{},
        do: {envelope["data"]["reply_id"], envelope["data"]["author_profile_id"]}
      )

  defp public_id(agent), do: Patchbay.Identity.get_wallet_profile!(8453, agent.wallet).public_id

  # Every event the callbacks were sent, by callback address.
  defp delivered do
    receive do
      {:delivered, %{url: url}, envelope} -> [{url, envelope} | delivered()]
    after
      0 -> []
    end
  end

  defp feed(conn, agent, thread_id) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post("/forum/updates", Jason.encode!(%{"thread_ids" => [thread_id]}))
    |> json_response(200)
  end

  defp hosted_feed(conn, agent, thread_id) do
    %{"result" => %{"structuredContent" => feed}} =
      conn
      |> rpc(agent, "tools/call", %{
        "name" => "get_updates",
        "arguments" => %{"thread_ids" => [thread_id]}
      })
      |> json_response(200)

    feed
  end

  defp subscribe!(conn, agent, thread_id, name, url) do
    assert %{"result" => %{"id" => "sub_" <> _}} =
             conn
             |> rpc(agent, "events/subscribe", subscription(thread_id, name, url))
             |> json_response(200)
  end

  defp subscription(thread_id, name, url) do
    %{
      "name" => name,
      "arguments" => %{"thread_ids" => [thread_id]},
      "delivery" => %{
        "mode" => "webhook",
        "url" => url,
        "secret" => "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
      }
    }
  end

  defp ask!(conn, agent) do
    %{"thread_id" => thread_id} =
      conn
      |> recycle()
      |> SignedAgent.sign(agent)
      |> post(
        "/forum/threads",
        Jason.encode!(%{
          "site" => "quiet.example.net",
          "title" => "Can this site amend a reservation?",
          "body_markdown" => "I found create_reservation but nothing to amend one.",
          "client_request_id" => Ecto.UUID.generate()
        })
      )
      |> json_response(201)

    thread_id
  end

  defp reply!(conn, agent, thread_id) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads/#{thread_id}/replies",
      Jason.encode!(%{
        "body_markdown" => "Call amend_reservation.",
        "client_request_id" => Ecto.UUID.generate()
      })
    )
    |> json_response(201)
  end

  # Patchbay's own answer, as its worker writes it: nobody signed in wrote it.
  defp patchbay_reply!(thread_id) do
    Patchbay.Forum.add_operator_reply!(
      %{report_id: thread_id, verdict: :verified_failure, note: "Patchbay saw the same failure."},
      authorize?: false
    ).id
  end

  defp mark!(conn, agent, thread_id, reply_id) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post("/forum/threads/#{thread_id}/solution", Jason.encode!(%{"reply_id" => reply_id}))
    |> json_response(201)
  end

  defp rpc(conn, agent, method, params) do
    conn
    |> recycle()
    |> SignedAgent.sign(agent)
    |> post("/mcp", rpc(method, params))
  end

  defp rpc(method, params),
    do: Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})

  # A live token the person granted ChatGPT at the open address, as its token
  # endpoint leaves it: only its hash.
  defp connect!(person) do
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

    bearer = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    token =
      Patchbay.Repo.insert!(%Token{
        type: "access_token",
        value: RegentOAuth.hash_token(bearer),
        client_id: client.id,
        sub: person.privy_user_id,
        scope: "patchbay.events.read",
        expires_at: System.system_time(:second) + 3600
      })

    :ok = PatchbayWeb.SiteEdition.within(:open, fn -> RegentOAuth.bind(token.id) end)
    bearer
  end
end
