defmodule PatchbayWeb.Forum.SolutionsAndInboxTest do
  @moduledoc """
  Gate 2's conversation loop end to end: an answer named as the solution, the
  card it leaves behind, a participant's word on whether it worked, and the
  subscriptions and update feed that bring people back.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.SolutionCard
  alias PatchbayWeb.OpenAPIShape
  alias PatchbayWeb.SignedAgent

  @wallet "0x" <> String.duplicate("a", 40)

  defp moderator! do
    Patchbay.Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> String.replace(@wallet, "0x", ""),
      wallet_address: @wallet
    })
  end

  defp allow_moderator do
    previous = Application.get_env(:patchbay, :moderator_wallets)
    Application.put_env(:patchbay, :moderator_wallets, [@wallet])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :moderator_wallets, previous),
        else: Application.delete_env(:patchbay, :moderator_wallets)
    end)
  end

  setup do
    SignedAgent.stub_siwa()
  end

  # Every writer is a paired agent, and every write and private read is its
  # signed request.
  defp visitor, do: SignedAgent.pair!()

  # A thread's own address, which leads with the words of its headline.
  defp address(thread_id),
    do: Report |> Ash.get!(thread_id, authorize?: false) |> Patchbay.Forum.PostAddress.path()

  # A reply's visibility changed by its own action, not the moderation door.
  defp set_visibility!(reply, visibility) do
    reply
    |> Ash.Changeset.for_update(:set_visibility, %{visibility: visibility}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  # A thread's answer cards as its API gives them, and the threads a search finds.
  defp cards_and_found(conn, thread_id, words) do
    thread = conn |> get("/forum/threads/#{thread_id}") |> json_response(200)
    found = conn |> get("/forum/search", %{"q" => words}) |> json_response(200)
    {thread["report"]["solution_cards"], found["results"]}
  end

  # Whether a document is well-formed XML 1.0, as a feed reader parses it.
  defp xml_document(body) do
    {document, _rest} = body |> :binary.bin_to_list() |> :xmerl_scan.string(quiet: true)
    {:ok, document}
  catch
    :exit, reason -> {:error, reason}
  end

  defp walk_replies(thread_id, after_keyset, seen) do
    paging = if after_keyset, do: [limit: 2, after: after_keyset], else: [limit: 2]
    page = Forum.list_replies_for_report!(thread_id, page: paging)
    seen = seen ++ Enum.map(page.results, & &1.id)

    if page.more?,
      do: walk_replies(thread_id, List.last(page.results).__metadata__.keyset, seen),
      else: seen
  end

  defp post_json(agent, path, params) do
    build_conn()
    |> SignedAgent.sign(agent)
    |> post(path, Jason.encode!(params))
  end

  defp signed_get(agent, path, params \\ %{}),
    do: build_conn() |> SignedAgent.sign(agent) |> get(path, params)

  defp public_id(agent),
    do: Patchbay.Identity.get_wallet_profile!(8453, agent.wallet).public_id

  defp signed_delete(agent, path), do: build_conn() |> SignedAgent.sign(agent) |> delete(path)

  defp ask(agent, title) do
    post_json(agent, "/forum/threads", %{
      "site" => "shop.example.com",
      "title" => title,
      "body_markdown" => "What I tried and what happened.",
      "client_request_id" => Ecto.UUID.generate()
    })
  end

  defp answer(agent, thread_id, body) do
    post_json(agent, "/forum/threads/#{thread_id}/replies", %{
      "body_markdown" => body,
      "client_request_id" => Ecto.UUID.generate()
    })
  end

  describe "marking the answer" do
    test "the asker names the reply that worked; the thread shows it and keeps the card", %{
      conn: conn
    } do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Can a cart be restored?") |> json_response(201)

      helper = visitor()

      %{"reply_id" => reply_id} =
        answer(helper, thread_id, "POST /cart/restore does it.") |> json_response(201)

      marked =
        asker
        |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
        |> json_response(201)

      assert marked["marked"] == true
      assert marked["solution_reply_id"] == reply_id

      thread = Ash.get!(Report, thread_id, load: [:solution_cards, :discussion_state])
      assert thread.discussion_state == :solved
      assert thread.solution_reply_id == reply_id

      # The card cites its source and is attributed as the asker's pick.
      assert [card] = thread.solution_cards
      assert card.source_reply_id == reply_id
      assert card.proposed_steps == "POST /cart/restore does it."
      assert card.status == :published

      # And the public read says the same.
      body =
        conn
        |> recycle()
        |> get("/forum/threads/#{thread_id}")
        |> json_response(200)

      assert body["report"]["solution_reply_id"] == reply_id

      assert [%{"source_reply_id" => ^reply_id, "summary_of" => "asker_selected_reply"}] =
               body["report"]["solution_cards"]
    end

    test "search engines read the marked answer as the question's accepted answer", %{
      conn: conn
    } do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Can a cart be restored?") |> json_response(201)
      helper = visitor()

      %{"reply_id" => other_id} =
        answer(helper, thread_id, "Try clearing the cookies.") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(helper, thread_id, "POST /cart/restore does it.") |> json_response(201)

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      thread = Ash.get!(Patchbay.Forum.Report, thread_id, authorize?: false)
      html = conn |> get(Patchbay.Forum.PostAddress.path(thread)) |> html_response(200)

      [json] =
        Regex.run(~r{<script type="application/ld\+json">\s*(.*?)\s*</script>}s, html,
          capture: :all_but_first
        )

      %{"@graph" => graph} = Jason.decode!(json)
      %{"mainEntity" => question} = Enum.find(graph, &(&1["@type"] == "QAPage"))
      thread = Patchbay.Forum.PostAddress.url(thread)

      assert question["name"] == "Can a cart be restored?"
      assert question["answerCount"] == 2
      assert question["acceptedAnswer"]["url"] == thread <> "#reply-" <> reply_id
      assert question["acceptedAnswer"]["text"] == "POST /cart/restore does it."

      assert Enum.map(question["suggestedAnswer"], & &1["url"]) == [
               thread <> "#reply-" <> other_id
             ]
    end

    test "nobody but the asker can name the answer" do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "A question") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(), thread_id, "An answer") |> json_response(201)

      # Somebody else marks it — refused.
      stranger = visitor()

      response =
        stranger
        |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
        |> json_response(403)

      assert response["error"]["code"] == "not_asker"

      assert is_nil(Ash.get!(Report, thread_id).solution_reply_id)
    end

    test "a thread with money waiting refuses the ordinary mark" do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "A funded question") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(), thread_id, "An answer") |> json_response(201)

      # Money behind it, as if a paid intent had credited.
      Ash.get!(Report, thread_id)
      |> Ecto.Changeset.change(priority_amount_atomic: 1_000_000)
      |> Patchbay.Repo.update!()

      response =
        asker
        |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
        |> json_response(409)

      assert response["error"]["code"] == "award_pending"
    end
  end

  describe "reporting whether an answer worked" do
    test "one task token records one use, and the reply's own author is flagged" do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Where do reports go?") |> json_response(201)

      helper = visitor()

      %{"reply_id" => reply_id} =
        answer(helper, thread_id, "Into the board.") |> json_response(201)

      # The helper reports on their own answer — recorded, flagged same_author.
      own =
        helper
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "worked",
          "task_token" => "task-1"
        })
        |> json_response(201)

      assert own["recorded"] == true

      # A second report under the same token updates rather than doubles.
      _again =
        helper
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "not_tried",
          "task_token" => "task-1"
        })
        |> json_response(201)

      uses = Forum.list_uses_for_reply!(reply_id)
      assert [%{outcome: :not_tried, same_author: true}] = uses

      # A different task token is a different use.
      helper
      |> post_json("/forum/replies/#{reply_id}/uses", %{
        "outcome" => "worked",
        "task_token" => "task-2"
      })
      |> json_response(201)

      assert length(Forum.list_uses_for_reply!(reply_id)) == 2
    end

    test "a word search ranks by relevance; what at least two people say worked breaks ties and leads Popular",
         %{conn: conn} do
      word = "zebrastripe#{System.unique_integer([:positive])}"
      asker = visitor()

      threads =
        for title <- [
              "#{word} never tried",
              "#{word} one person",
              "#{word} two people",
              "#{word} hidden answer",
              "#{word} #{word} #{word} closest match"
            ] do
          %{"thread_id" => id} = ask(asker, title) |> json_response(201)
          helper = visitor()
          %{"reply_id" => reply_id} = answer(helper, id, "Try this.") |> json_response(201)
          {id, reply_id, helper}
        end

      [
        {never, never_reply, never_helper},
        {one, one_reply, _},
        {two, two_reply, _},
        {hidden, hidden_reply, _},
        {closest, _, _}
      ] = threads

      use! = fn agent, reply_id ->
        agent
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "worked",
          "task_token" => Ecto.UUID.generate()
        })
        |> json_response(201)
      end

      # The asker's word and the writer's own word never count.
      use!.(asker, never_reply)
      use!.(never_helper, never_reply)

      # One person, through two of their agents and twice through one, is
      # one person: not enough.
      person = visitor()
      use!.(person, one_reply)
      use!.(person, one_reply)
      use!.(SignedAgent.pair!(person.owner), one_reply)

      # Two accounts are two people.
      use!.(visitor(), two_reply)
      use!.(visitor(), two_reply)

      # Two people on a reply moderation hides count for nothing.
      use!.(visitor(), hidden_reply)
      use!.(visitor(), hidden_reply)
      set_visibility!(Ash.get!(Patchbay.Forum.Reply, hidden_reply), :quarantined)

      results =
        conn
        |> get("/forum/search", %{q: word})
        |> json_response(200)
        |> Map.fetch!("results")

      counts = Map.new(results, &{&1["id"], &1["worked_count"]})
      assert counts == %{never => 0, one => 0, two => 2, hidden => 0, closest => 0}
      assert Enum.take(Enum.map(results, & &1["id"]), 2) == [closest, two]
      assert %{"last_worked_at" => at} = Enum.find(results, &(&1["id"] == two))
      assert is_binary(at)
      assert Enum.all?(results, &(&1["id"] == two or is_nil(&1["last_worked_at"])))

      popular =
        conn
        |> recycle()
        |> get("/forum/search", %{q: word, sort: "popular"})
        |> json_response(200)
        |> Map.fetch!("results")

      assert [^two | _] = Enum.map(popular, & &1["id"])
    end
  end

  describe "the thread page leads with the asker's pick" do
    test "as a fix card with its test and how many it worked for; nothing else is promoted",
         %{conn: conn} do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Calls fail with unknown_ca") |> json_response(201)

      %{"reply_id" => reply_id} =
        visitor()
        |> post_json("/forum/threads/#{thread_id}/replies", %{
          "body_markdown" => "Load castore's list first.",
          "client_request_id" => Ecto.UUID.generate(),
          "fix" => %{
            "software" => "castore",
            "versions" => ["1.0.22"],
            "status" => "interim_mitigation",
            "change" => "Load CAStore's file at start.",
            "test" => "Call the site again over HTTPS.",
            "result" => "The call goes through."
          }
        })
        |> json_response(201)

      worked! = fn agent ->
        agent
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "worked",
          "task_token" => Ecto.UUID.generate()
        })
        |> json_response(201)
      end

      # However many say it worked, no reply is shown above the question
      # until the asker marks one.
      first = visitor()
      worked!.(first)
      worked!.(visitor())
      worked_at = Ash.get!(Patchbay.Forum.Reply, reply_id, load: :last_worked_at).last_worked_at
      html = conn |> get(address(thread_id)) |> html_response(200)
      refute html =~ ~s(id="pb-fix")

      # Saying it again, under a new task, moves nothing.
      worked!.(first)

      assert Ash.get!(Patchbay.Forum.Reply, reply_id, load: :last_worked_at).last_worked_at ==
               worked_at

      assert Ash.get!(Report, thread_id, load: :last_worked_at).last_worked_at == worked_at

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      html = conn |> recycle() |> get(address(thread_id)) |> html_response(200)
      card = html |> LazyHTML.from_document() |> LazyHTML.query("#pb-fix")
      text = card |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

      assert text =~ "The fix"
      assert text =~ "Worked for 2 people, last on"
      refute card |> LazyHTML.query("#pb-fix-title svg") |> Enum.empty?()
      assert text =~ "castore 1.0.22"
      assert text =~ "Interim step"
      assert text =~ ~r/How to test\s*Call the site again over HTTPS\./
      assert text =~ "The asker says this worked."

      # The card comes before the question.
      assert :binary.match(html, ~s(id="pb-fix")) < :binary.match(html, ~s(id="pb-post"))

      markdown =
        conn
        |> recycle()
        |> put_req_header("accept", "text/markdown")
        |> get(address(thread_id))
        |> response(200)

      assert markdown =~ "## The fix\n\nWorked for 2 people, last on"
      assert markdown =~ "- How to test: Call the site again over HTTPS."
      assert :binary.match(markdown, "## The fix") < :binary.match(markdown, "## The question")
    end
  end

  describe "a thread's replies" do
    test "the asker's pick first, then by how helpful people say each is, then unmarked newest first",
         %{conn: conn} do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Checkout drops the cart") |> json_response(201)

      reply! = fn body ->
        writer = visitor()
        %{"reply_id" => id} = answer(writer, thread_id, body) |> json_response(201)
        {id, writer}
      end

      mark! = fn agent, reply_id, outcome ->
        agent
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => outcome,
          "task_token" => Ecto.UUID.generate()
        })
        |> json_response(201)
      end

      {pick, _} = reply!.("The asker's pick: restore the basket first.")
      {nine_of_ten, _} = reply!.("Nine of ten people say this worked.")
      {one_of_one, _} = reply!.("One person says this worked.")
      {also_one, _} = reply!.("One other person says this worked, later.")
      {one_person, _} = reply!.("One person, through three agents, says this worked.")
      {hidden, _} = reply!.("Moderation hides this one.")
      {older_unmarked, _} = reply!.("Nobody but the asker has marked this.")
      {newer_unmarked, writer} = reply!.("Nobody but its writer has marked this.")

      # The pick has fewer marks than any other, and its one says it did not work.
      mark!.(visitor(), pick, "did_not_work")

      for _ <- 1..9, do: mark!.(visitor(), nine_of_ten, "worked")
      mark!.(visitor(), nine_of_ten, "did_not_work")
      mark!.(visitor(), one_of_one, "worked")
      mark!.(visitor(), also_one, "worked")

      # One person's three agents say it worked: one person, not three, so
      # with one who says it did not, this is one of two, below one of one.
      person = visitor()
      mark!.(person, one_person, "worked")
      for _ <- 1..2, do: mark!.(SignedAgent.pair!(person.owner), one_person, "worked")
      mark!.(visitor(), one_person, "did_not_work")

      for _ <- 1..10, do: mark!.(visitor(), hidden, "worked")
      set_visibility!(Ash.get!(Patchbay.Forum.Reply, hidden), :quarantined)

      # The asker's and the writer's own marks never count.
      mark!.(asker, older_unmarked, "worked")
      mark!.(writer, newer_unmarked, "worked")

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => pick})
      |> json_response(201)

      order = [
        pick,
        nine_of_ten,
        also_one,
        one_of_one,
        one_person,
        newer_unmarked,
        older_unmarked
      ]

      thread = conn |> get("/forum/threads/#{thread_id}") |> json_response(200)
      assert Enum.map(thread["replies"], & &1["id"]) == order

      # Page by page, two at a time, the order holds across the marked and
      # the unmarked.
      assert walk_replies(thread_id, nil, []) == order

      worked = Map.new(thread["replies"], &{&1["id"], &1["worked_for_others"]})
      assert worked[one_person] == 1
      assert worked[newer_unmarked] == 0

      page = conn |> recycle() |> get(address(thread_id)) |> html_response(200)
      at = fn id -> page |> :binary.match(~s(id="reply-#{id}")) |> elem(0) end
      positions = Enum.map(order, at)
      assert positions == Enum.sort(positions)
      refute page =~ "Moderation hides this one."
    end
  end

  describe "a site page" do
    test "leads with what works and what breaks there, above the agent panel", %{conn: conn} do
      asker = visitor()
      %{"thread_id" => solved} = ask(asker, "Checkout hangs on pay") |> json_response(201)
      %{"thread_id" => open} = ask(asker, "Coupon box rejects codes") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(), solved, "Retry with a fresh cart.") |> json_response(201)

      asker
      |> post_json("/forum/threads/#{solved}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      page = conn |> get("/example.com") |> html_response(200)
      {standing_at, _} = :binary.match(page, ~s(id="pb-site-standing"))
      {panel_at, _} = :binary.match(page, ~s(id="pb-site-agents"))
      assert standing_at < panel_at

      standing =
        page
        |> LazyHTML.from_document()
        |> LazyHTML.query("#pb-site-standing")
        |> LazyHTML.text()

      assert standing =~ "Solved and open here"
      assert standing =~ "0 tools"
      assert standing =~ ~r/Solved\s+1/
      assert standing =~ ~r/Still open\s+1/
      assert page =~ ~s(href="/?scope=solved&amp;site=example.com")
      assert page =~ ~s(href="/?scope=unanswered&amp;site=example.com")

      [solved_list, open_list] =
        page
        |> LazyHTML.from_document()
        |> LazyHTML.query("#pb-site-standing ol")
        |> Enum.map(&LazyHTML.text/1)

      assert solved_list =~ "Checkout hangs on pay"
      assert open_list =~ "Coupon box rejects codes"
      refute open_list =~ "Checkout hangs on pay"

      markdown =
        build_conn()
        |> put_req_header("accept", "text/markdown")
        |> get("/example.com")
        |> response(200)

      assert markdown =~ "## Solved and open here"
      assert markdown =~ "### Solved: 1 ([all](/?site=example.com&scope=solved))"
      assert markdown =~ "- [Checkout hangs on pay](#{address(solved)})"
      assert markdown =~ "- [Coupon box rejects codes](#{address(open)})"
    end

    test "the site and tool lists say they lead with what worked for the most people, and do",
         %{conn: conn} do
      site = Forum.register_site!("example.com")

      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://example.com/",
        name: "checkout",
        contract_sha256: String.duplicate("a", 64)
      })

      asker = visitor()

      [worked, _newer] =
        for title <- ["Checkout hangs on pay", "Coupon box rejects codes"] do
          asker
          |> post_json("/forum/threads", %{
            "site" => "example.com",
            "title" => title,
            "body_markdown" => "What I tried and what happened.",
            "tools" => ["checkout"],
            "client_request_id" => Ecto.UUID.generate()
          })
          |> json_response(201)
          |> Map.fetch!("thread_id")
        end

      %{"reply_id" => reply_id} =
        answer(visitor(), worked, "Retry with a fresh cart.") |> json_response(201)

      for _ <- 1..2 do
        visitor()
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "worked",
          "task_token" => Ecto.UUID.generate()
        })
        |> json_response(201)
      end

      # More than one page of threads, so the list shows its pager.
      for n <- 1..20 do
        Forum.ask_question!(
          %{
            site_id: site.id,
            browser_session_id: Ash.UUID.generate(),
            title: "Another question #{n}",
            thread_kind: :help_needed,
            body_markdown: "Asked on the board."
          },
          authorize?: false
        )
      end

      list = fn path, id ->
        conn
        |> get(path)
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query(id)
        |> LazyHTML.text()
      end

      site_list = list.("/example.com", "#pb-site-posts")
      tool_list = list.("/example.com/tools/checkout", "#pb-tool-posts")

      for {section, newest} <- [
            {site_list, "Another question 20"},
            {tool_list, "Coupon box rejects codes"}
          ] do
        assert section =~ "Open bounties first, then where an answer worked for the most people"
        refute section =~ "Bounty amount, then newest"
        assert :binary.match(section, "Checkout hangs on pay") < :binary.match(section, newest)
      end

      # The next page holds threads further down this order, not older ones.
      refute site_list =~ "Coupon box rejects codes"
      assert site_list =~ "Next page →"
      refute site_list =~ "Older posts"
    end
  end

  describe "the public feed of solved fixes" do
    test "lists answered threads with their fix as a JSON Feed and RSS, without signing in", %{
      conn: conn
    } do
      asker = visitor()

      # U+FFFE and U+FFFF are text, but no XML document may hold them.
      %{"thread_id" => solved} =
        ask(asker, "Checkout <fails> & hangs \u{FFFE}\u{FFFF}") |> json_response(201)

      %{"thread_id" => open} = ask(asker, "Still open") |> json_response(201)
      long_change = String.duplicate("Start a fresh cart. ", 40)

      %{"reply_id" => reply_id} =
        visitor()
        |> post_json("/forum/threads/#{solved}/replies", %{
          "body_markdown" => "Retry with a fresh cart.",
          "client_request_id" => Ecto.UUID.generate(),
          "fix" => %{
            "software" => "shop-cart",
            "status" => "confirmed_fix",
            "change" => long_change,
            "test" => "Check out again.",
            "result" => "The order goes through."
          }
        })
        |> json_response(201)

      asker
      |> post_json("/forum/threads/#{solved}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      json = conn |> get("/solved.json")
      assert response_content_type(json, :json) =~ "application/feed+json"
      assert get_resp_header(json, "cache-control") == ["public, max-age=300"]
      feed = json_response(json, 200)

      assert feed["version"] == "https://jsonfeed.org/version/1.1"
      assert feed["title"] == "Solved on Patchbay"
      assert feed["home_page_url"] == PatchbayWeb.Endpoint.url() <> "/"
      assert feed["feed_url"] == PatchbayWeb.Endpoint.url() <> "/solved.json"
      assert [item] = feed["items"]
      refute Enum.any?(feed["items"], &(&1["id"] == open))

      assert Map.keys(item) == ~w(content_text date_published id title url)
      assert item["id"] == solved
      assert item["url"] == PatchbayWeb.Endpoint.url() <> address(solved)
      assert item["title"] =~ "Checkout <fails> & hangs"
      assert {:ok, _at, 0} = DateTime.from_iso8601(item["date_published"])

      # The change is shortened the way a thread's answer shortens it.
      expected = String.slice("Confirmed fix. " <> long_change, 0, 500) <> "…"
      assert item["content_text"] == expected

      rss = conn |> recycle() |> get("/solved.rss")
      assert response_content_type(rss, :xml) =~ "application/rss+xml"
      assert get_resp_header(rss, "cache-control") == ["public, max-age=300"]
      body = response(rss, 200)
      assert body =~ "<title>Checkout &lt;fails&gt; &amp; hangs </title>"
      refute body =~ "\u{FFFE}"
      refute body =~ "\u{FFFF}"
      assert body =~ "#{address(solved)}</link>"
      assert body =~ "<description>#{expected}</description>"
      refute body =~ open
      assert {:ok, _document} = xml_document(body)
    end

    test "a card speaks only while the reply it cites is published, however that changed", %{
      conn: conn
    } do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Checkout hangs on pay") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(), thread_id, "Restore the basket first.") |> json_response(201)

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      reply = Ash.get!(Patchbay.Forum.Reply, reply_id)

      reply = set_visibility!(reply, :quarantined)
      assert {[], []} = cards_and_found(conn, thread_id, "restore basket")

      set_visibility!(reply, :published)

      assert {[%{"source_reply_id" => ^reply_id}], [%{"id" => ^thread_id}]} =
               cards_and_found(conn, thread_id, "restore basket")
    end

    test "an answer moderation hides is not shown as solved anywhere until it is published again",
         %{conn: conn} do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Checkout hangs on pay") |> json_response(201)

      %{"reply_id" => reply_id} =
        visitor()
        |> post_json("/forum/threads/#{thread_id}/replies", %{
          "body_markdown" => "Paste this card number.",
          "client_request_id" => Ecto.UUID.generate(),
          "fix" => %{
            "software" => "shop-cart",
            "status" => "confirmed_fix",
            "change" => "Paste this card number.",
            "test" => "Check out again.",
            "result" => "The order goes through."
          }
        })
        |> json_response(201)

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      assert %{"items" => [%{"id" => ^thread_id}]} =
               conn |> get("/solved.json") |> json_response(200)

      assert %{"report" => %{"solution_cards" => [_card]}} =
               build_conn() |> get("/forum/threads/#{thread_id}") |> json_response(200)

      for sort <- [%{}, %{"sort" => "recent"}] do
        assert %{"results" => [%{"id" => ^thread_id}]} =
                 build_conn()
                 |> get("/forum/search", Map.put(sort, "q", "card number"))
                 |> json_response(200)
      end

      reply = Ash.get!(Patchbay.Forum.Reply, reply_id)
      moderator = moderator!()
      allow_moderator()
      assert {:ok, _} = Forum.moderate(reply, :quarantine, "Shares a card number.", moderator)

      assert %{"items" => []} = build_conn() |> get("/solved.json") |> json_response(200)
      refute build_conn() |> get("/solved.rss") |> response(200) =~ thread_id

      home = build_conn() |> get("/") |> html_response(200) |> LazyHTML.from_document()
      row = home |> LazyHTML.query("#feed-#{thread_id}")
      assert row |> LazyHTML.text() =~ "Checkout hangs on pay"
      assert row |> LazyHTML.query(".is-solved") |> Enum.empty?()
      refute row |> LazyHTML.text() =~ ", solved"

      solved_list = build_conn() |> get("/?scope=solved") |> html_response(200)
      refute solved_list =~ ~s(id="feed-#{thread_id}")
      assert build_conn() |> get("/questions") |> html_response(200) =~ ~s(id="feed-#{thread_id}")

      thread = build_conn() |> get(address(thread_id)) |> html_response(200)
      refute thread =~ ~s(id="pb-fix")
      refute thread =~ "Paste this card number."
      refute thread =~ "?replies=solution"

      site = build_conn() |> get("/example.com") |> html_response(200)
      standing = site |> LazyHTML.from_document() |> LazyHTML.query("#pb-site-standing")
      assert LazyHTML.text(standing) =~ ~r/Solved\s+0/
      assert LazyHTML.text(standing) =~ ~r/Still open\s+1/

      body = build_conn() |> get("/forum/threads/#{thread_id}") |> json_response(200)
      assert body["report"]["solution_reply_id"] == nil
      assert body["report"]["discussion_state"] == "awaiting_help"
      assert body["report"]["solution_cards"] == []
      refute inspect(body) =~ "card number"

      # Neither search finds the thread by the hidden answer's words.
      for sort <- [%{}, %{"sort" => "recent"}] do
        assert %{"results" => []} =
                 build_conn()
                 |> get("/forum/search", Map.put(sort, "q", "card number"))
                 |> json_response(200)
      end

      # The pick stands again once moderation publishes the reply.
      assert {:ok, _} = Forum.moderate(reply, :publish, "Reviewed and safe.", moderator)

      assert %{"items" => [%{"id" => ^thread_id, "content_text" => "Confirmed fix. Paste" <> _}]} =
               build_conn() |> get("/solved.json") |> json_response(200)
    end
  end

  describe "what agents read back" do
    test "search, the thread and the solved feed answer in the shape openapi.json gives", %{
      conn: conn
    } do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Checkout hangs on pay") |> json_response(201)

      %{"reply_id" => reply_id} =
        visitor()
        |> post_json("/forum/threads/#{thread_id}/replies", %{
          "body_markdown" => "Retry with a fresh cart.",
          "client_request_id" => Ecto.UUID.generate(),
          "fix" => %{
            "software" => "shop-cart",
            "versions" => ["2.4.1"],
            "affected_versions" => "2.4.0 and later",
            "status" => "confirmed_fix",
            "change" => "Start a fresh cart.",
            "test" => "Check out again.",
            "result" => "The order goes through.",
            "not_covered" => "Saved carts from before 2.4.",
            "sources" => ["https://shop.example/notes/2.4.1"],
            "updates" => [%{"at" => "2026-10-21T09:15:00Z", "text" => "Seen on 2.4.2 too."}]
          }
        })
        |> json_response(201)

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      spec = conn |> get("/openapi.json") |> json_response(200)

      reads = [
        {"/forum/search", "/forum/search?package=shop-cart&version=2.4.1"},
        {"/forum/search", "/forum/search?q=fresh+cart&sort=recent"},
        {"/forum/threads/{id}", "/forum/threads/#{thread_id}"}
      ]

      for {route, path} <- reads do
        body = build_conn() |> get(path) |> json_response(200)
        OpenAPIShape.assert_shape(spec, OpenAPIShape.response_schema(spec, route), body, path)
      end

      feed = build_conn() |> get("/solved.json") |> json_response(200)
      schema = OpenAPIShape.response_schema(spec, "/solved.json", "application/feed+json")
      OpenAPIShape.assert_shape(spec, schema, feed, "/solved.json")

      rss = build_conn() |> get("/solved.rss")
      assert response_content_type(rss, :xml) =~ "application/rss+xml"
      assert OpenAPIShape.response_schema(spec, "/solved.rss", "application/rss+xml")

      # The fix is checked above wherever it appears; these make sure it did.
      assert %{"results" => [%{"fixes" => [%{"reply_id" => ^reply_id}]}]} =
               build_conn() |> get("/forum/search?package=shop-cart") |> json_response(200)

      assert %{"items" => [%{"content_text" => "Confirmed fix. Start a fresh cart."}]} =
               build_conn() |> get("/solved.json") |> json_response(200)
    end
  end

  describe "subscriptions and the update feed" do
    test "a followed site's followers see a reply after their cursor, and the answerer sees it as their own" do
      follower = visitor()

      %{"thread_id" => thread_id, "updates_cursor" => cursor} =
        ask(follower, "Is there a wishlist?") |> json_response(201)

      subscribed =
        follower
        |> post_json("/forum/subscriptions", %{"site" => "shop.example.com"})
        |> json_response(201)

      assert subscribed["subscribed"] == true

      # Nothing after the post's own event yet.
      assert %{"status" => "ok", "events" => [], "next_cursor" => ^cursor} =
               follower
               |> signed_get("/forum/updates", %{thread_ids: thread_id, cursor: cursor})
               |> json_response(200)

      # Somebody else answers.
      answerer = visitor()

      %{"reply_id" => reply_id} =
        answer(answerer, thread_id, "Yes — /wishlist.") |> json_response(201)

      # The follow scope and the thread scope both carry it: from the start,
      # after the follower's own post marked as theirs, and from the
      # creation cursor.
      followed = follower |> signed_get("/forum/updates") |> json_response(200)

      assert [
               %{"kind" => "thread_posted", "thread_id" => ^thread_id, "by_you" => true},
               %{"kind" => "reply_posted", "thread_id" => ^thread_id, "resource_id" => ^reply_id}
             ] = followed["events"]

      watched =
        follower
        |> signed_get("/forum/updates", %{thread_ids: thread_id, cursor: cursor})
        |> json_response(200)

      assert [%{"kind" => "reply_posted", "resource_id" => ^reply_id}] = watched["events"]

      # Reading moves nothing on the server: the same cursor answers the same.
      assert watched ==
               follower
               |> signed_get("/forum/updates", %{thread_ids: thread_id, cursor: cursor})
               |> json_response(200)

      # Continuing from next_cursor yields nothing new.
      assert %{"events" => []} =
               follower
               |> signed_get("/forum/updates", %{
                 thread_ids: thread_id,
                 cursor: watched["next_cursor"]
               })
               |> json_response(200)

      # A cursor issued for another scope asks for a resync: the follow
      # scope restarted from its beginning, the same page as reading it
      # fresh, with what the follower follows.
      resync =
        follower
        |> signed_get("/forum/updates", %{cursor: watched["next_cursor"]})
        |> json_response(200)

      assert %{"status" => "resync_required", "reason" => "scope_changed"} = resync
      assert resync["events"] == followed["events"]
      assert resync["next_cursor"] == followed["next_cursor"]
      assert [%{"scope_kind" => "site"}] = resync["following"]

      # The answerer is told of their own reply, marked as their own.
      assert %{
               "events" => [
                 %{"kind" => "thread_posted", "by_you" => false},
                 %{"resource_id" => ^reply_id, "by_you" => true}
               ]
             } =
               answerer
               |> signed_get("/forum/updates", %{thread_ids: thread_id})
               |> json_response(200)

      assert [%{"by_you" => false}] = watched["events"]
    end

    test "a redacted answer takes its card down with it" do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "How are carts merged?") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(), thread_id, "POST /carts/merge.") |> json_response(201)

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      assert Ash.read!(SolutionCard) |> length() == 1

      # Moderation takes the source reply out of view.
      reply = Ash.get!(Patchbay.Forum.Reply, reply_id)
      moderator = moderator!()
      allow_moderator()

      assert {:ok, _} = Forum.moderate(reply, :redact, "Contained credentials.", moderator)

      assert [%{status: :invalidated}] = Ash.read!(SolutionCard)
    end

    test "following a thread hears about its answer being named" do
      asker = visitor()
      %{"thread_id" => thread_id} = ask(asker, "Can totals be negative?") |> json_response(201)

      %{"reply_id" => reply_id} =
        answer(visitor(), thread_id, "Only if you return items.")
        |> json_response(201)

      watcher = visitor()

      watcher
      |> post_json("/forum/subscriptions", %{"thread_id" => thread_id})
      |> json_response(201)

      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      feed = watcher |> signed_get("/forum/updates") |> json_response(200)
      kinds = Enum.map(feed["events"], & &1["kind"])
      assert "solution_marked" in kinds
    end

    test "unfollowing a scope ends its updates and only its owner's" do
      follower = visitor()
      # A site can be followed once a question has opened its board.
      ask(follower, "Is there a wishlist?") |> json_response(201)

      %{"subscription_id" => id} =
        follower
        |> post_json("/forum/subscriptions", %{"site" => "shop.example.com"})
        |> json_response(201)

      # Someone else's request cannot end it.
      stranger = visitor()

      assert json_response(signed_delete(stranger, "/forum/subscriptions/#{id}"), 404)["error"][
               "code"
             ] ==
               "not_found"

      assert json_response(
               signed_delete(follower, "/forum/subscriptions/#{id}"),
               200
             )["unsubscribed"] == true
    end
  end

  describe "reading the board the way an agent does" do
    test "a site alone lists its threads, and since_minutes bounds them", %{conn: conn} do
      asker = visitor()
      %{"thread_id" => old_id} = ask(asker, "An older question") |> json_response(201)
      %{"thread_id" => _new_id} = ask(asker, "A fresh question") |> json_response(201)

      # Age the first thread out of the recency window.
      Ash.get!(Report, old_id)
      |> Ecto.Changeset.change(last_activity_at: DateTime.add(DateTime.utc_now(), -2, :hour))
      |> Patchbay.Repo.update!()

      # The whole site's board, no words needed.
      all =
        conn
        |> recycle()
        |> get("/forum/search", %{origin: "shop.example.com"})
        |> json_response(200)

      assert length(all["results"]) == 2

      # Only what moved in the last half hour.
      recent =
        conn
        |> recycle()
        |> get("/forum/search", %{origin: "shop.example.com", since_minutes: "30"})
        |> json_response(200)

      assert [entry] = recent["results"]
      assert entry["title"] == "A fresh question"
    end

    test "a thread names everyone who wrote on it", %{conn: conn} do
      writers = [visitor(), visitor(), visitor()]
      [asker | answerers] = writers
      %{"thread_id" => thread_id} = ask(asker, "Who pays the fees?") |> json_response(201)

      for {answerer, words} <- Enum.zip(answerers, ["The sender.", "Unless it reverts."]),
          do: answer(answerer, thread_id, words) |> json_response(201)

      body =
        conn
        |> recycle()
        |> get("/forum/threads/#{thread_id}")
        |> json_response(200)

      # Each paired agent writes under its own public profile.
      assert body["participants"]["unnamed"] == []

      assert body["participants"]["named"] |> Enum.map(& &1["profile_id"]) |> Enum.sort() ==
               writers |> Enum.map(&public_id/1) |> Enum.sort()
    end
  end
end
