defmodule PatchbayWeb.IncidentControllerTest do
  @moduledoc """
  The incident pages: each one is its own discussion with the briefing as the
  opening post, at one address; the list of them; and the home page's badge
  while any is live. Tests read the repository's incidents and a closed one
  kept with the tests (`test/support/incidents`).
  """

  # The sitemap reads the shared Wallet Bench, one reading for the whole run.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Incidents
  alias Patchbay.Incidents.Discussion

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp reply!(thread, note) do
    Forum.add_reply!(
      %{
        report_id: thread.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :unknown,
        note: note
      },
      authorize?: false
    )
  end

  # A post copied from one cve.now record, as `Patchbay.Incidents.CveNow` writes it.
  defp cve_post!(n) do
    site = Forum.register_site!("cve.now")

    Forum.mirror_cve_now!(%{
      site_id: site.id,
      title: "CVE-2026-#{100_000 + n}: Example gateway flaw #{n}",
      body_markdown: "An attacker can run code.",
      topic_tags: ["cve-2026-#{100_000 + n}"],
      browser_session_id: Patchbay.Config.agent_session_id(),
      cve_now_id: "CVE-2026-#{100_000 + n}",
      cve_now_modified_at: DateTime.utc_now()
    })
  end

  defp paths(posts), do: Enum.map(posts, &PostAddress.path/1)

  defp attributes(nodes, name), do: nodes |> Enum.flat_map(&LazyHTML.attribute(&1, name))

  defp person!(subject) do
    Patchbay.Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate(subject, 40)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id, System.os_time(:second))
  end

  defp say_worked(conn, thread, reply, person, wanted \\ "true") do
    conn
    |> signed_in(person)
    |> post(~p"/posts/#{thread.id}/worked", %{"reply_id" => reply.id, "worked" => wanted})
  end

  test "an incident's page is one discussion, opening with its briefing", %{conn: conn} do
    emudhra = Incidents.get("emudhra")

    html = conn |> get(~p"/incidents/emudhra") |> html_response(200)
    assert html =~ emudhra.title
    assert html =~ "Actions"

    # A second read finds the same thread.
    {:ok, thread} = Forum.get_incident_discussion("emudhra")
    conn |> get(~p"/incidents/emudhra") |> html_response(200)
    assert {:ok, %{id: same}} = Discussion.open(emudhra)
    assert same == thread.id
    assert thread.body_markdown == emudhra.body
    assert thread.topic_tags == [emudhra.tag]

    markdown = conn |> get("/incidents/emudhra.md") |> response(200)
    assert markdown =~ "# #{emudhra.title}"
    assert markdown =~ "## Actions"
    assert markdown =~ "/forum/threads/#{thread.id}/replies"

    asked =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(~p"/incidents/emudhra")

    assert [type] = get_resp_header(asked, "content-type")
    assert type =~ "text/markdown"
  end

  test "a discussion has one address, the incident's page", %{conn: conn} do
    {:ok, thread} = Discussion.open(Incidents.get("emudhra"))

    assert conn |> get(~p"/posts/#{thread.id}") |> redirected_to(301) == "/incidents/emudhra"

    assert conn |> get(~p"/posts/#{thread.id}/some-words") |> redirected_to(301) ==
             "/incidents/emudhra"

    # A person's reply lands back on the page, with the reply on it.
    response =
      conn
      |> signed_in(person!("a"))
      |> post(~p"/threads/#{thread.id}/replies", %{
        "reply" => %{"body_markdown" => "Updating the trust store fixed it"}
      })

    landed = redirected_to(response)
    assert landed =~ "/incidents/emudhra"
    assert conn |> get(landed) |> html_response(200) =~ "Updating the trust store fixed it"
  end

  test "a new file changes the opening post, and the replies stay", %{conn: conn} do
    emudhra = Incidents.get("emudhra")
    {:ok, thread} = Discussion.open(emudhra)
    reply!(thread, "Still seeing this on Node 24")

    {:ok, _stale} =
      Forum.refresh_incident_briefing(thread, %{
        title: "An earlier title",
        body_markdown: "Earlier words"
      })

    html = conn |> get(~p"/incidents/emudhra") |> html_response(200)
    assert html =~ emudhra.title
    refute html =~ "Earlier words"
    assert html =~ "Still seeing this on Node 24"
    assert {:ok, %{id: same}} = Forum.get_incident_discussion("emudhra")
    assert same == thread.id
  end

  test "the reply enough people say worked is marked as the fix, and a later one can pass it",
       %{conn: conn} do
    {:ok, thread} = Discussion.open(Incidents.get("emudhra"))
    first = reply!(thread, "Update the trust store")
    later = reply!(thread, "Update the trust store and restart the service")
    [a, b, c] = Enum.map(~w(a b c), &person!/1)

    say_worked(conn, thread, first, a)
    assert {:ok, %{solution_reply_id: nil}} = Forum.get_incident_discussion("emudhra")

    # Saying it twice is one person's word.
    say_worked(conn, thread, first, a)
    assert {:ok, %{solution_reply_id: nil}} = Forum.get_incident_discussion("emudhra")

    say_worked(conn, thread, first, b)
    assert {:ok, %{solution_reply_id: marked}} = Forum.get_incident_discussion("emudhra")
    assert marked == first.id

    assert conn |> get(~p"/incidents/emudhra") |> html_response(200) =~ "id=\"pb-fix\""

    # Level does not take over; ahead does.
    say_worked(conn, thread, later, a)
    say_worked(conn, thread, later, b)
    assert {:ok, %{solution_reply_id: ^marked}} = Forum.get_incident_discussion("emudhra")

    say_worked(conn, thread, later, c)
    assert {:ok, %{solution_reply_id: now}} = Forum.get_incident_discussion("emudhra")
    assert now == later.id
  end

  test "a reader's press shows on their next read and can be taken back", %{conn: conn} do
    {:ok, thread} = Discussion.open(Incidents.get("emudhra"))
    reply = reply!(thread, "Update the trust store")
    person = person!("a")

    pressed = fn ->
      conn
      |> signed_in(person)
      |> get(~p"/incidents/emudhra")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(form[action="/posts/#{thread.id}/worked"] button))
      |> LazyHTML.attribute("aria-pressed")
    end

    assert pressed.() == ["false"]
    assert redirected_to(say_worked(conn, thread, reply, person)) =~ "/incidents/emudhra"
    assert pressed.() == ["true"]
    assert redirected_to(say_worked(conn, thread, reply, person, "false")) =~ "/incidents/emudhra"
    assert pressed.() == ["false"]
  end

  test "a reader who is not signed in is told to, and nothing is saved", %{conn: conn} do
    {:ok, thread} = Discussion.open(Incidents.get("emudhra"))
    reply = reply!(thread, "Update the trust store")

    response =
      post(conn, ~p"/posts/#{thread.id}/worked", %{"reply_id" => reply.id, "worked" => "true"})

    assert redirected_to(response) =~ "/incidents/emudhra"
    assert Forum.get_reply!(reply.id, load: [:worked_for_others]).worked_for_others == 0
  end

  test "an ordinary thread offers no Worked button and keeps its asker's mark", %{conn: conn} do
    site = Forum.register_site!("nodejs.org")

    thread =
      Forum.ask_question!(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "Node 24 streams stop after a minute",
          thread_kind: :help_needed,
          body_markdown: "What I changed and how I tested it."
        },
        authorize?: false
      )

    reply = reply!(thread, "Set a longer timeout")

    assert {:error, _} = Forum.refresh_incident_briefing(thread, %{body_markdown: "Other words"})

    html =
      conn
      |> signed_in(person!("a"))
      |> get(Patchbay.Forum.PostAddress.path(thread))
      |> html_response(200)

    refute html =~ "/posts/#{thread.id}/worked"

    for subject <- ~w(a b) do
      say_worked(conn, thread, reply, person!(subject))
    end

    assert Forum.get_reply!(reply.id, load: [:worked_for_others]).worked_for_others == 2
    assert %{solution_reply_id: nil} = Forum.get_report!(thread.id)
  end

  test "a name with no incident file is a missing page", %{conn: conn} do
    assert conn |> get("/incidents/no-such-incident") |> html_response(404)
    assert conn |> get("/incidents/no-such-incident.md") |> response(404)
  end

  test "the list shows each incident, live ones first, with its checked day and replies",
       %{conn: conn} do
    {:ok, thread} = Discussion.open(Incidents.get("emudhra"))
    reply!(thread, "Update the trust store")

    html = conn |> get(~p"/incidents") |> html_response(200)
    rows = html |> LazyHTML.from_document() |> LazyHTML.query(".pb-incident-row")
    texts = Enum.map(rows, &(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    emudhra = Incidents.get("emudhra")
    day = PatchbayWeb.IncidentHTML.day(emudhra.checked)

    assert Enum.any?(texts, &(&1 =~ "#{emudhra.title} Live Checked #{day} 1 reply"))
    assert List.last(texts) =~ "A closed drill Closed Checked 16 January 2026 0 replies"

    markdown = conn |> get("/incidents.md") |> response(200)
    assert markdown =~ "[#{emudhra.title}](/incidents/emudhra.md) — Live"
    assert markdown =~ "1 reply"

    # A closed incident keeps its page.
    assert conn |> get(~p"/incidents/drill") |> html_response(200) =~ "Closed"
  end

  test "the list shows the critical CVEs copied from cve.now first, newest first, then the incidents",
       %{conn: conn} do
    older = cve_post!(1)
    newer = cve_post!(2)
    reply!(older, "Patched")

    html = conn |> get(~p"/incidents") |> html_response(200) |> LazyHTML.from_document()

    sections = html |> LazyHTML.query("#patchbay-incidents > section") |> attributes("id")
    assert sections == ["patchbay-cves", "patchbay-briefings"]

    incident_links =
      html |> LazyHTML.query("#patchbay-briefings .pb-incident-list > li > a") |> attributes("href")

    assert "/incidents/emudhra" in incident_links

    rows = LazyHTML.query(html, "#patchbay-cves .pb-incident-row")

    assert attributes(LazyHTML.query(rows, ".pb-incident-row-title"), "href") ==
             paths([newer, older])

    assert rows |> Enum.at(1) |> LazyHTML.text() =~ "1 reply"

    markdown = conn |> get("/incidents.md") |> response(200)
    assert markdown =~ "(/incidents/emudhra.md)"
    [_opening, cves, _briefings] = String.split(markdown, ["## Critical CVEs", "## Briefings"])
    links = Regex.scan(~r{\]\((/posts/[^)]+)\)}, cves, capture: :all_but_first) |> List.flatten()
    assert links == paths([newer, older])
  end

  test "the critical CVEs are paged 25 at a time, with the incidents on the first page only",
       %{conn: conn} do
    posts = Enum.map(1..26, &cve_post!/1)
    [oldest | _rest] = posts

    first = conn |> get(~p"/incidents") |> html_response(200) |> LazyHTML.from_document()
    assert first |> LazyHTML.query("#patchbay-cves .pb-incident-row") |> Enum.count() == 25

    assert first |> LazyHTML.query(".pb-incident-pages a[rel=next]") |> attributes("href") == [
             "/incidents?page=2"
           ]

    second = conn |> get(~p"/incidents?page=2") |> html_response(200) |> LazyHTML.from_document()

    assert second |> LazyHTML.query(".pb-incident-row-title") |> attributes("href") ==
             paths([oldest])

    assert second |> LazyHTML.query(".pb-incident-pages a[rel=prev]") |> attributes("href") == [
             "/incidents"
           ]

    markdown = conn |> get("/incidents.md?page=2") |> response(200)
    refute markdown =~ "/incidents/emudhra"
    assert markdown =~ PostAddress.path(oldest)
    assert conn |> get("/incidents.md") |> response(200) =~ "(/incidents.md?page=2)"

    for page <- ["3", "1", "two", "02"] do
      assert_error_sent(404, fn -> get(conn, "/incidents?page=#{page}") end)
    end
  end

  test "while an incident is live, the home page has one badge to the incidents page and no lines",
       %{conn: conn} do
    live = Incidents.active()
    assert live != []

    home = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert [badge] = home |> LazyHTML.query(".pb-home-incidents a") |> Enum.to_list()
    assert LazyHTML.attribute(badge, "href") == ["/incidents"]

    assert badge |> LazyHTML.query(".rg-tone--warning") |> LazyHTML.text() =~
             "Active cyber incidents"

    for incident <- Incidents.all() do
      refute LazyHTML.to_html(home) =~ "/incidents/#{incident.name}"
    end

    markdown = conn |> put_req_header("accept", "text/markdown") |> get(~p"/") |> response(200)
    assert markdown =~ "Active cyber incidents: [/incidents](/incidents.md)."
    refute markdown =~ "/incidents/"
  end

  test "a discussion stays out of the home list and is found by narrowing it", %{conn: conn} do
    {:ok, thread} = Discussion.open(Incidents.get("emudhra"))
    {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{})

    for sort <- ["recent", "popular"] do
      home = conn |> get(~p"/?sort=#{sort}") |> html_response(200)
      refute home =~ "/incidents/emudhra"
    end

    listed? = fn filters ->
      page =
        Forum.list_feed_reports!(query: Patchbay.Forum.Feed.query(filters), page: [limit: 50])

      Enum.any?(page.results, &(&1.id == thread.id))
    end

    site = Ash.load!(thread, :site, authorize?: false).site

    refute listed?.(filters)
    assert listed?.(%{filters | q: "eMudhra"})
    assert listed?.(%{filters | site: site.origin})
    assert listed?.(%{filters | tag: hd(thread.topic_tags)})

    assert conn |> get(~p"/incidents") |> html_response(200) =~ "/incidents/emudhra"
  end

  test "with no live incident there is no badge" do
    assert render_component(&PatchbayWeb.Forum.BoardHTML.incidents_badge/1, incidents: []) =~
             ~r/\A\s*\z/

    badge =
      render_component(&PatchbayWeb.Forum.BoardHTML.incidents_badge/1,
        incidents: Incidents.active()
      )

    assert badge =~ ~s(href="/incidents")
    assert badge =~ "Active cyber incidents"
  end

  test "the sitemap lists the incidents and each one's page", %{conn: conn} do
    PatchbayTest.SharedBench.share!()
    {:ok, _thread} = Discussion.open(Incidents.get("emudhra"))
    xml = conn |> get(~p"/sitemap.xml") |> response(200)

    paths = ["/incidents" | Enum.map(Incidents.all(), &("/incidents/" <> &1.name))]

    for path <- paths do
      entry = "<loc>#{PatchbayWeb.Endpoint.url()}#{path}</loc>"
      assert [_before, _after] = String.split(xml, entry)
    end
  end
end
