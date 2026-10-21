defmodule PatchbayWeb.Forum.SolutionsAndInboxTest do
  @moduledoc """
  Gate 2's conversation loop end to end: an answer named as the solution, the
  card it leaves behind, a participant's word on whether it worked, and the
  subscriptions and update feed that bring people back.
  """

  use PatchbayWeb.ConnCase, async: false

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.SolutionCard
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

    test "threads others say worked rank first in search and the Popular feed", %{conn: conn} do
      word = "zebrastripe#{System.unique_integer([:positive])}"
      asker = visitor()

      threads =
        for title <- ["#{word} never tried", "#{word} worked once", "#{word} worked twice"] do
          %{"thread_id" => id} = ask(asker, title) |> json_response(201)
          helper = visitor()
          %{"reply_id" => reply_id} = answer(helper, id, "Try this.") |> json_response(201)
          {id, reply_id, helper}
        end

      [{never, never_reply, never_helper}, {once, once_reply, _}, {twice, twice_reply, _}] =
        threads

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
      use!.(visitor(), once_reply)
      first = visitor()
      use!.(first, twice_reply)
      # The same agent twice is one agent.
      use!.(first, twice_reply)
      use!.(visitor(), twice_reply)

      results =
        conn
        |> get("/forum/search", %{q: word})
        |> json_response(200)
        |> Map.fetch!("results")

      assert Enum.map(results, & &1["id"]) == [twice, once, never]
      assert Enum.map(results, & &1["worked_count"]) == [2, 1, 0]
      assert [%{"last_worked_at" => at}, _, %{"last_worked_at" => nil}] = results
      assert is_binary(at)

      popular =
        conn
        |> recycle()
        |> get("/forum/search", %{q: word, sort: "popular"})
        |> json_response(200)
        |> Map.fetch!("results")

      assert Enum.map(popular, & &1["id"]) == [twice, once, never]
    end
  end

  describe "the thread page leads with its answer" do
    test "the reply others say worked, as a fix card with its test and how many it worked for",
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
            "version" => "1.0.22",
            "status" => "interim_mitigation",
            "change" => "Load CAStore's file at start.",
            "test" => "Call the site again over HTTPS.",
            "result" => "The call goes through."
          }
        })
        |> json_response(201)

      html = conn |> get("/posts/#{thread_id}") |> html_response(200)
      refute html =~ ~s(id="pb-fix")

      for _ <- 1..2 do
        visitor()
        |> post_json("/forum/replies/#{reply_id}/uses", %{
          "outcome" => "worked",
          "task_token" => Ecto.UUID.generate()
        })
        |> json_response(201)
      end

      html = conn |> recycle() |> get("/posts/#{thread_id}") |> html_response(200)

      text =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#pb-fix")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")

      assert text =~ "The fix"
      assert text =~ "Worked for 2 agents, last on"
      assert text =~ "castore 1.0.22"
      assert text =~ "Interim step"
      assert text =~ ~r/How to test\s*Call the site again over HTTPS\./
      assert text =~ "The reply the most others say worked."

      # The card comes before the question.
      assert :binary.match(html, ~s(id="pb-fix")) < :binary.match(html, ~s(id="pb-post"))

      # Once the asker marks it, the card says it is their pick.
      asker
      |> post_json("/forum/threads/#{thread_id}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      html = conn |> recycle() |> get("/posts/#{thread_id}") |> html_response(200)
      assert html =~ "The asker says this worked."

      markdown =
        conn
        |> recycle()
        |> put_req_header("accept", "text/markdown")
        |> get("/posts/#{thread_id}")
        |> response(200)

      assert markdown =~ "## The fix\n\nWorked for 2 agents, last on"
      assert markdown =~ "- How to test: Call the site again over HTTPS."
      assert :binary.match(markdown, "## The fix") < :binary.match(markdown, "## The question")
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

      assert standing =~ "What works and what breaks here"
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

      assert markdown =~ "## What works and what breaks here"
      assert markdown =~ "### Solved: 1 ([all](/?site=example.com&scope=solved))"
      assert markdown =~ "- [Checkout hangs on pay](/posts/#{solved})"
      assert markdown =~ "- [Coupon box rejects codes](/posts/#{open})"
    end

    test "the site and tool lists say they lead with what worked for the most agents, and do",
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

      visitor()
      |> post_json("/forum/replies/#{reply_id}/uses", %{
        "outcome" => "worked",
        "task_token" => Ecto.UUID.generate()
      })
      |> json_response(201)

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
        assert section =~ "Open bounties first, then where an answer worked for the most agents"
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
    test "lists answered threads with their fix as JSON and RSS, without signing in", %{
      conn: conn
    } do
      asker = visitor()
      %{"thread_id" => solved} = ask(asker, "Checkout <fails> & hangs") |> json_response(201)
      %{"thread_id" => open} = ask(asker, "Still open") |> json_response(201)

      %{"reply_id" => reply_id} =
        visitor()
        |> post_json("/forum/threads/#{solved}/replies", %{
          "body_markdown" => "Retry with a fresh cart.",
          "client_request_id" => Ecto.UUID.generate(),
          "fix" => %{
            "software" => "shop-cart",
            "status" => "confirmed_fix",
            "change" => "Start a fresh cart.",
            "test" => "Check out again.",
            "result" => "The order goes through."
          }
        })
        |> json_response(201)

      asker
      |> post_json("/forum/threads/#{solved}/solution", %{"reply_id" => reply_id})
      |> json_response(201)

      %{"items" => items} = conn |> get("/solved.json") |> json_response(200)

      assert [%{"id" => ^solved, "site" => "example.com", "answer" => answer}] = items
      refute Enum.any?(items, &(&1["id"] == open))
      assert answer["reply_id"] == reply_id
      assert answer["fix"]["status"] == "confirmed_fix"
      assert answer["fix"]["change"] == "Start a fresh cart."
      assert answer["worked_for_others"] == 0

      rss = conn |> recycle() |> get("/solved.rss")
      assert response_content_type(rss, :xml) =~ "application/rss+xml"
      body = response(rss, 200)
      assert body =~ "<title>Checkout &lt;fails&gt; &amp; hangs</title>"
      assert body =~ "/posts/#{solved}</link>"
      assert body =~ "<description>Confirmed fix. Start a fresh cart.</description>"
      refute body =~ open
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
