defmodule PatchbayWeb.IncidentControllerTest do
  @moduledoc """
  The incident pages: each one's own account and the fixes agents posted
  under its tag, the list of them, and the home page's line while any is
  live. Tests read the repository's incidents and a closed one kept with the
  tests (`test/support/incidents`).
  """

  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Forum
  alias Patchbay.Incidents

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp ask!(site, title, tags) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: "What I changed and how I tested it.",
        topic_tags: tags
      },
      authorize?: false
    )
  end

  test "an incident's page shows its account and only the threads with its tag", %{conn: conn} do
    site = Forum.register_site!("nodejs.org")
    fix = ask!(site, "Node 24 refuses the eMudhra test host after an update", ["emudhra"])
    other = ask!(site, "Node 24 streams stop after a minute", ["streams"])

    emudhra = Incidents.get("emudhra")
    html = conn |> get(~p"/incidents/emudhra") |> html_response(200)

    assert html =~ emudhra.title
    assert html =~ "Do this now"
    assert html =~ ~s(href="/incidents/emudhra.md")
    assert html =~ ~s(href="/posts/#{fix.id}")
    refute html =~ ~s(href="/posts/#{other.id}")

    markdown = conn |> get("/incidents/emudhra.md") |> response(200)
    assert markdown =~ "# #{emudhra.title}"
    assert markdown =~ "## Do this now"
    assert markdown =~ "(/posts/#{fix.id})"
    refute markdown =~ "(/posts/#{other.id})"

    asked =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(~p"/incidents/emudhra")

    assert [type] = get_resp_header(asked, "content-type")
    assert type =~ "text/markdown"
    assert response(asked, 200) == markdown
  end

  test "Share a fix opens the home form with the incident's site and tag, and leaves the list whole",
       %{conn: conn} do
    site = Forum.register_site!("nodejs.org")
    untagged = ask!(site, "Node 24 streams stop after a minute", [])

    html = conn |> get(~p"/incidents/emudhra") |> html_response(200)

    [share] =
      Regex.run(~r{href="(/\?[^"]*topic_tags=emudhra[^"]*)"}, html, capture: :all_but_first)

    share = String.replace(share, "&amp;", "&")
    assert share == "/?site_url=emudhra.com&topic_tags=emudhra#pb-hero"

    home = conn |> get(share) |> html_response(200) |> LazyHTML.from_document()

    assert ["emudhra"] =
             home
             |> LazyHTML.query(~s(input[name="ask[topic_tags]"]))
             |> LazyHTML.attribute("value")

    assert ["emudhra.com"] =
             home
             |> LazyHTML.query(~s(input[name="ask[site_url]"]))
             |> LazyHTML.attribute("value")

    assert [_open] = home |> LazyHTML.query("#pb-hero-details[open]") |> Enum.to_list()

    # The tag fills the form only: the questions below are not narrowed to it.
    assert LazyHTML.to_html(home) =~ ~s(href="/posts/#{untagged.id}")
  end

  test "a name with no incident file is a missing page", %{conn: conn} do
    assert conn |> get("/incidents/no-such-incident") |> html_response(404)
    assert conn |> get("/incidents/no-such-incident.md") |> response(404)
  end

  test "the list shows each incident, live ones first, with its tagged threads counted",
       %{conn: conn} do
    site = Forum.register_site!("nodejs.org")
    ask!(site, "Node 24 refuses the eMudhra test host after an update", ["emudhra"])
    ask!(site, "Node 24 streams stop after a minute", ["streams"])

    html = conn |> get(~p"/incidents") |> html_response(200)
    rows = html |> LazyHTML.from_document() |> LazyHTML.query(".pb-incident-row")

    texts = Enum.map(rows, &(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    title = Incidents.get("emudhra").title

    assert [_php, emudhra, _pingcap, drill] = texts
    assert emudhra =~ "#{title} Live 20 October 2026 1 thread"
    assert drill =~ "A closed drill Closed 15 January 2026 0 threads"

    markdown = conn |> get("/incidents.md") |> response(200)
    assert markdown =~ "[#{title}](/incidents/emudhra.md) — Live"
    assert markdown =~ "1 thread"

    # A closed incident keeps its page.
    assert conn |> get(~p"/incidents/drill") |> html_response(200) =~ "Closed"
  end

  test "the home page has a line for each live incident, linking to its page, and one to them all",
       %{conn: conn} do
    live = Incidents.active()
    assert live != []

    home = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    lines = home |> LazyHTML.query(".pb-home-incident") |> Enum.to_list()

    assert length(lines) == length(live)

    for {line, incident} <- Enum.zip(lines, live) do
      assert [_mark] = line |> LazyHTML.query(".rg-tone--warning") |> Enum.to_list()

      assert [href] = line |> LazyHTML.query("a") |> LazyHTML.attribute("href")
      assert href == "/incidents/#{incident.name}"
      assert LazyHTML.text(line) =~ incident.title
    end

    assert ["/incidents"] =
             home
             |> LazyHTML.query(~s(.pb-home-incidents a[href="/incidents"]))
             |> LazyHTML.attribute("href")

    refute LazyHTML.to_html(home) =~ "/incidents/drill"

    markdown = conn |> put_req_header("accept", "text/markdown") |> get(~p"/") |> response(200)
    assert markdown =~ "(/incidents.md)"

    for incident <- live do
      assert markdown =~ "- Live: [#{incident.title}](/incidents/#{incident.name}.md)"
    end

    refute markdown =~ "/incidents/drill"
  end

  test "the sitemap lists the incidents and each one's page", %{conn: conn} do
    xml = conn |> get(~p"/sitemap.xml") |> response(200)

    for path <-
          ~w(/incidents /incidents/emudhra /incidents/php-cve-2026-109618 /incidents/pingcap-tidb-cloud /incidents/drill) do
      assert xml =~ "<loc>#{PatchbayWeb.Endpoint.url()}#{path}</loc>"
    end
  end
end
