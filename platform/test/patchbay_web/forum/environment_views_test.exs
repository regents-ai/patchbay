defmodule PatchbayWeb.Forum.EnvironmentViewsTest do
  use PatchbayWeb.ConnCase, async: false
  alias Patchbay.Forum
  alias PatchbayWeb.Forum.Discussions

  setup do
    actor =
      Patchbay.Identity.upsert_from_wallet!(%{wallet_address: "0x" <> String.duplicate("8", 40)})

    site = Forum.register_site!("environment.example")

    approver =
      Patchbay.Identity.upsert_from_privy!(%{
        privy_user_id: "environment-approver",
        wallet_address: "0x" <> String.duplicate("9", 40)
      })

    grant =
      Ash.create!(
        Patchbay.Forum.PublicationGrant,
        %{
          subject_wallet: actor.wallet_address,
          mode: :task,
          purpose: "Public environment discussions",
          operations: [:ask_question],
          public_confirmation: true
        },
        action: :approve,
        actor: approver
      )

    %{actor: actor, site: site, grant: grant}
  end

  defp question(c, environment, title \\ "Slot question") do
    Forum.ask_question!(
      %{
        site_id: c.site.id,
        title: title,
        body_markdown: "Which slot is available?",
        machine_principal: "profile:" <> c.actor.id,
        publication_grant_id: c.grant.id,
        operation_id: Ecto.UUID.generate(),
        operation_name: :ask_question,
        submission_transport: :mcp_agent,
        target_interface: if(environment == "grok", do: "muse", else: "webmcp"),
        agent_environment: environment,
        client_request_id: Ecto.UUID.generate(),
        request_digest: String.duplicate("a", 64)
      },
      actor: c.actor
    )
  end

  test "declared environments select only exact published records and reuse canonical threads",
       c do
    muse = question(c, "muse")
    grok = question(c, "grok")
    similar = question(c, "musebook")
    hidden = question(c, "muse")

    hidden
    |> Ash.Changeset.for_update(:set_visibility, %{visibility: :quarantined})
    |> Ash.update!(authorize?: false)

    {:ok, {_, reply}} =
      PatchbayWeb.ForumAPI.Participation.post_reply(Ecto.UUID.generate(), nil, muse.id, %{
        "body_markdown" => "Use the afternoon slot.",
        "reply_kind" => "answer"
      })

    assert {:ok, _} = Forum.mark_solution(muse, reply.id, nil, c.actor)

    assert {:ok, answer_use} =
             PatchbayWeb.ForumAPI.Participation.record_answer_use(
               Ecto.UUID.generate(),
               nil,
               reply.id,
               %{"task_token" => "slot-task", "outcome" => "worked"}
             )

    [card] = Ash.load!(muse, :solution_cards).solution_cards

    legacy =
      Forum.ask_question!(%{
        site_id: c.site.id,
        title: "Browser question",
        body_markdown: "A browser question",
        browser_session_id: Ecto.UUID.generate()
      })

    for format <- ["text/html", "text/markdown"] do
      response =
        build_conn()
        |> put_req_header("accept", format)
        |> get("/?agent_environment=muse")
        |> response(200)

      assert response =~ "/posts/#{muse.id}"

      for excluded <- [grok, similar, hidden, legacy],
          do: refute(response =~ "/posts/#{excluded.id}")

      assert response =~ "Declared agent environment"
      assert response =~ "unverified"
      assert response =~ "Target interface"
      assert response =~ "Submission channel"
      assert response =~ "mcp_agent"

      thread =
        build_conn()
        |> put_req_header("accept", format)
        |> get("/posts/#{muse.id}")
        |> response(200)

      assert thread =~ reply.id
      assert thread =~ "Use the afternoon slot."
      assert thread =~ "environment.example"
      assert thread =~ "webmcp"
      assert thread =~ "Declared agent environment"
      assert thread =~ card.proposed_steps
      assert thread =~ "The short of it"

      legacy_thread =
        build_conn()
        |> put_req_header("accept", format)
        |> get("/posts/#{legacy.id}")
        |> response(200)

      refute legacy_thread =~ "Declared agent environment"

      grok_view =
        build_conn()
        |> put_req_header("accept", format)
        |> get("/?agent_environment=grok")
        |> response(200)

      assert grok_view =~ "/posts/#{grok.id}"
      refute grok_view =~ "/posts/#{muse.id}"
    end

    assert Ash.get!(Patchbay.Forum.AnswerUse, answer_use.id).reply_id == reply.id
    assert Ash.get!(Patchbay.Forum.SolutionCard, card.id).thread_id == muse.id
  end

  test "environment pagination stays bound to search site scope and exact environment", c do
    reports = for i <- 1..21, do: question(c, "muse", "Slot #{i}")
    question(c, "grok")
    question(c, "musebook")

    filters =
      Discussions.filters(%{
        "agent_environment" => "muse",
        "q" => "Slot",
        "site" => c.site.origin,
        "scope" => "unanswered"
      })

    assert {:ok, first, token} = Discussions.page(filters, [], nil)
    assert length(first) == 20
    assert {:ok, last, nil} = Discussions.page(filters, [], token)
    assert Enum.sort(Enum.map(first ++ last, & &1.id)) == Enum.sort(Enum.map(reports, & &1.id))

    for {key, value} <- [
          agent_environment: "grok",
          agent_environment: "",
          q: "other",
          site: "other.example",
          scope: "all"
        ] do
      assert {:error, :invalid_cursor} = Discussions.page(Map.put(filters, key, value), [], token)
    end

    assert {:ok, [], nil} = Discussions.page(%{filters | q: "absent"}, [], nil)
    assert {:ok, [], nil} = Discussions.page(%{filters | site: "other.example"}, [], nil)
    assert {:ok, [], nil} = Discussions.page(%{filters | scope: "following"}, [], nil)
  end

  test "rendered navigation preserves combined filters and onboarding exposes real connector limits",
       c do
    muse = question(c, "muse")
    grok = question(c, "grok")
    path = "/?agent_environment=muse&q=Slot&site=environment.example&scope=unanswered"
    html = build_conn() |> get(path) |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert LazyHTML.query(doc, ~s(nav[aria-label="Declared agent environment"] a[href="/"]))
           |> LazyHTML.text() == "All discussions"

    assert LazyHTML.query(doc, "#connector-context-#{muse.id} > summary") |> LazyHTML.text() =~
             "Connector context"

    assert Enum.empty?(LazyHTML.query(doc, "#connector-context-#{muse.id}[open]"))

    assert LazyHTML.query(doc, "#connector-context-#{muse.id}") |> LazyHTML.text() =~
             "Declared agent environment"

    assert LazyHTML.query(doc, ".pb-feed-tabs [aria-current=page]") |> LazyHTML.text() ==
             "Muse connector help"

    assert length(Enum.to_list(LazyHTML.query(doc, "input[name=agent_environment][value=muse]"))) ==
             2

    md = build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)
    assert md =~ "[All discussions](/)"
    all = build_conn() |> get("/") |> html_response(200)
    assert all =~ "/posts/#{grok.id}"
    assert all =~ "/posts/#{muse.id}"
    [_, following] = Regex.run(~r/\[Following\]\(([^)]+)\)/, md)

    assert URI.decode_query(URI.parse(following).query) == %{
             "agent_environment" => "muse",
             "q" => "Slot",
             "site" => "environment.example",
             "scope" => "following"
           }

    assert build_conn() |> get(following) |> html_response(200) =~ "No public discussions match"

    for format <- ["text/html", "text/markdown"], agent <- ["muse", "local"] do
      start =
        build_conn()
        |> put_req_header("accept", format)
        |> get("/start?agent=#{agent}")
        |> response(200)

      assert start =~ "read-only"
      assert start =~ "SIWA"
      assert start =~ "no payment tools"
      refute start =~ "anonymous connection"
    end
  end
end
