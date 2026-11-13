defmodule PatchbayWeb.LivePostsTest do
  # The lists of posts and a post's thread stay current while they are open
  # (`PatchbayWeb.PostListLive`, `PatchbayWeb.ThreadLive`): what is published
  # arrives, what moderation holds leaves, and an open page reads nothing when
  # either happens.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Identity
  alias Patchbay.ModeratorFixtures
  alias PatchbayWeb.ForumAPI.Participation
  alias PatchbayWeb.LivePart
  alias PatchbayWeb.PostListLive
  alias PatchbayWeb.ThreadLive

  setup do
    site = Forum.register_site!("live.example")
    other = Forum.register_site!("elsewhere.example")
    %{site: site, other: other, asker: person("asker"), replier: person("replier")}
  end

  describe "the home page's posts" do
    test "a published post arrives at the top once; one moderation holds leaves", %{
      conn: conn,
      site: site,
      asker: asker
    } do
      earlier = ask(site, asker, "Why does the cart empty itself?")
      {:ok, view} = open(conn, "/", PostListLive)
      assert rows(view) == [earlier.id]

      post = ask(site, asker, "Why is the total wrong?")
      assert rows(view) == [post.id, earlier.id]
      assert view |> element("#feed-#{post.id}") |> render() =~ "Why is the total wrong?"
      # The page hears of it too, which pulses its activity strip.
      assert_push_event(view, "posts:arrived", %{list: "pb-home-posts"})

      hold(post)
      assert rows(view) == [earlier.id]

      # A reply to the held post does not bring it back.
      reply(post, asker, "Still wrong.")
      assert rows(view) == [earlier.id]
    end

    test "a reply and a like change a shown post's counts in place", %{
      conn: conn,
      site: site,
      asker: asker,
      replier: replier
    } do
      post = ask(site, asker, "Why is the total wrong?")
      {:ok, view} = open(conn, "/", PostListLive)

      answer = reply(post, replier, "Tax is added twice.")
      Forum.like!(post.id, answer.id, actor: asker, authorize?: false)
      Forum.like!(post.id, nil, actor: replier, authorize?: false)

      assert counts(view, post) == ["1", "1"]
      assert rows(view) == [post.id]
    end

    # An advisory copied from cve.now is news for cve.now's own list and the
    # Advisories tab, never one of the posts people and agents asked.
    test "an advisory copied from cve.now arrives on cve.now's list, never on the home list", %{
      conn: conn,
      site: site,
      asker: asker
    } do
      cve = Forum.register_site!("cve.now")
      earlier = advisory(cve, 1)
      {:ok, home} = open(conn, "/", PostListLive)
      {:ok, board} = open(conn, "/cve.now", PostListLive)
      assert rows(home) == []
      assert rows(board) == [earlier.id]

      copied = advisory(cve, 2)
      asked = ask(site, asker, "Why is the total wrong?")

      assert rows(home) == [asked.id]
      assert rows(board) == [copied.id, earlier.id]
    end
  end

  describe "a site's posts" do
    test "a post on the site arrives; one elsewhere does not; one moderation holds leaves", %{
      conn: conn,
      site: site,
      other: other,
      asker: asker
    } do
      {:ok, view} = open(conn, "/#{site.origin}", PostListLive)
      assert rows(view) == []
      assert render(view) =~ "No posts"

      post = ask(site, asker, "Why does the search time out?")
      ask(other, asker, "Why is the map blank?")
      assert rows(view) == [post.id]
      refute render(view) =~ "No posts"
      # Only the post that arrived is told to the page.
      assert_push_event(view, "posts:arrived", %{list: "pb-site-posts"})
      refute_push_event(view, "posts:arrived", %{})

      hold(post)
      assert rows(view) == []
    end
  end

  describe "a tool's posts" do
    test "a post naming the tool arrives; one naming another tool does not", %{
      conn: conn,
      site: site,
      asker: asker
    } do
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: String.duplicate("a", 64)
      })

      {:ok, view} = open(conn, "/#{site.origin}/tools/checkout", PostListLive)
      assert rows(view) == []

      post = ask(site, asker, "Why does checkout refuse my card?", ["checkout"])
      ask(site, asker, "Why does search time out?", ["search"])
      assert rows(view) == [post.id]

      assert view |> element("#feed-#{post.id}") |> render() =~
               "Why does checkout refuse my card?"
    end
  end

  describe "a post's thread" do
    setup %{site: site, asker: asker} do
      %{post: ask(site, asker, "Why does checkout fail?")}
    end

    test "a reply arrives at the end, and its likes, uses and pick change in place", %{
      conn: conn,
      post: post,
      asker: asker,
      replier: replier
    } do
      first = reply(post, replier, "Clear the cart first.")
      {:ok, view} = open(conn, PostAddress.path(post), ThreadLive)
      assert replies(view) == [first.id]

      second = reply(post, asker, "That did not help.")
      assert replies(view) == [first.id, second.id]
      assert view |> element("#patchbay-replies-title") |> render() =~ "2"

      Forum.like!(post.id, first.id, actor: asker, authorize?: false)
      Forum.like!(post.id, second.id, actor: replier, authorize?: false)
      assert view |> element("#reply-#{first.id} .rg-figure") |> render() =~ "1"
      assert view |> element("#reply-#{second.id} .rg-figure") |> render() =~ "1"

      {:ok, _use} =
        Participation.record_answer_use(person("reader"), first.id, %{
          "outcome" => "worked",
          "task_token" => "reader"
        })

      assert view |> element("#reply-#{first.id}") |> render() =~ "Worked for 1"

      {:ok, _marked} = Forum.mark_solution(post, first.id, nil, asker)
      assert has_element?(view, "#pb-fix")
      assert has_element?(view, "#reply-#{first.id}.rg-discussion__post--solution")
      assert replies(view) == [first.id, second.id]
    end

    test "a reply moderation holds leaves", %{conn: conn, post: post, replier: replier} do
      {:ok, view} = open(conn, PostAddress.path(post), ThreadLive)

      held = reply(post, replier, "Paste your card number here.")
      assert replies(view) == [held.id]

      hold(held)
      assert replies(view) == []
    end

    test "a thread moderation holds sends its reader to its address", %{conn: conn, post: post} do
      path = PostAddress.path(post)
      {:ok, view} = open(conn, path, ThreadLive)

      hold(post)
      assert_redirect(view, path)
    end
  end

  # Thirty agents post and thirty reply within moments, while twenty readers
  # have the home page open, one the site's page and one the thread. Every
  # page shows each new post or reply once, keeps to one page, and reads
  # nothing for any of it: each notice carries its row, read once by the
  # write that sent it.
  test "thirty agents posting at once reach every open page once, and the pages read nothing",
       %{conn: conn, site: site, asker: asker} do
    post = ask(site, asker, "Why does checkout fail?")
    path = PostAddress.path(post)
    homes = for _reader <- 1..20, do: elem(open(conn, "/", PostListLive), 1)
    {:ok, board} = open(conn, "/#{site.origin}", PostListLive)
    {:ok, thread} = open(conn, path, ThreadLive)
    agents = for n <- 1..30, do: person("agent-#{n}")

    {posts, reads} =
      reads_by_process(fn ->
        agents
        |> Task.async_stream(
          fn agent ->
            {self(), ask(site, agent, "Question from #{agent.id}"),
             reply(post, agent, "Answer from #{agent.id}")}
          end,
          max_concurrency: 30,
          ordered: false
        )
        |> Enum.map(fn {:ok, written} -> written end)
        |> tap(fn _written -> Enum.each([thread, board | homes], &render/1) end)
      end)

    asked = Enum.map(posts, &elem(&1, 1).id)
    replied = posts |> Enum.map(&elem(&1, 2).id) |> MapSet.new()

    for home <- homes do
      shown = rows(home)
      assert length(shown) == 10
      assert shown == Enum.uniq(shown)
      assert MapSet.subset?(MapSet.new(shown), MapSet.new(asked))
    end

    shown = rows(board)
    assert length(shown) == 20
    assert shown == Enum.uniq(shown)
    assert MapSet.subset?(MapSet.new(shown), MapSet.new([post.id | asked]))

    assert thread |> replies() |> MapSet.new() == replied
    assert length(replies(thread)) == 30
    assert thread |> element("#patchbay-replies-title") |> render() =~ "30"

    open_pages = Enum.map([thread, board | homes], & &1.pid)
    assert Map.take(reads, open_pages) == %{}

    # A post and a reply, with the reads for their notices: 25 or 26 when
    # measured, however many pages are open.
    for {writer, _post, _reply} <- posts, do: assert(Map.fetch!(reads, writer) <= 30)
  end

  # A page's live part, joined as the browser joins it.
  defp open(conn, path, view) do
    session = conn |> get(path) |> html_response(200) |> LivePart.session(view)
    {:ok, live, _html} = live_isolated(build_conn(), view, session: session)
    {:ok, live}
  end

  defp rows(view), do: ids(view, "li[id^='feed-']", "feed-")
  defp replies(view), do: ids(view, ".rg-discussion__replies > li[id^='reply-']", "reply-")

  defp ids(view, selector, prefix) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  defp counts(view, post) do
    view
    |> element("#feed-#{post.id}-stats")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-count]")
    |> Enum.map(&LazyHTML.text/1)
  end

  # Written as an agent's request writes it, after the request has checked who
  # is asking; these tests are about what open pages see, not who may post.
  defp ask(site, author, title, tools \\ []) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        title: title,
        thread_kind: :help_needed,
        body_markdown: "What I tried: " <> title,
        tool_names: tools,
        browser_session_id: Ash.UUID.generate()
      },
      actor: author,
      authorize?: false
    )
  end

  # As `Patchbay.Incidents.CveNow` copies a record.
  defp advisory(board, n) do
    Forum.mirror_cve_now!(%{
      site_id: board.id,
      title: "CVE-2026-#{100_000 + n}: Example gateway flaw #{n}",
      body_markdown: "An attacker can run code.",
      topic_tags: ["cve-2026-#{100_000 + n}"],
      browser_session_id: Patchbay.Config.agent_session_id(),
      cve_now_id: "CVE-2026-#{100_000 + n}",
      cve_now_modified_at: DateTime.utc_now()
    })
  end

  # As `ask/3`: who may reply is not under test here.
  defp reply(post, author, words) do
    Forum.add_reply!(
      %{
        report_id: post.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :unknown,
        note: words
      },
      actor: author,
      authorize?: false
    )
  end

  defp hold(subject) do
    {:ok, _held} =
      Forum.moderate(subject, :quarantine, "Held for review.", ModeratorFixtures.moderator())
  end

  defp person(name) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:live-" <> name,
      wallet_address: "0x" <> (:crypto.hash(:sha, name) |> Base.encode16(case: :lower))
    })
  end

  # How many database reads each process made while `run` ran.
  defp reads_by_process(run) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test, {:read, self()}) end,
      nil
    )

    result =
      try do
        run.()
      after
        :telemetry.detach(id)
      end

    {result, collect(%{})}
  end

  defp collect(reads) do
    receive do
      {:read, pid} -> collect(Map.update(reads, pid, 1, &(&1 + 1)))
    after
      0 -> reads
    end
  end
end
