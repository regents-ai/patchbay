defmodule Patchbay.Forum.SiteCheckTest do
  @moduledoc """
  A site's first post adds it to the directory: its check records the
  page's tools and a picture is taken. Every day each site is checked again,
  and its official source is verified again while it still mentions WebMCP.
  A picture that fails is tried three times, then again a day later, so an
  outage of the screenshot machine leaves no site without a card for good. A
  page that refuses the picture, or asks us to slow down, is asked once and
  tried again a day later. A check names only what is real, and says which code and packages
  come from the site and which only share its name.
  """

  use Patchbay.DataCase, async: false
  use AshOban.Test, repo: Patchbay.Repo

  @moduletag :capture_log

  alias Patchbay.Forum
  alias Patchbay.Forum.Catalog
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.SiteScan
  alias Patchbay.OutsideLists
  alias Patchbay.PageSite

  @picture "RIFF" <> <<4::little-32>> <> "WEBP" <> "VP8 "

  setup do
    old = Application.get_env(:patchbay, :shots_req_options)
    on_exit(fn -> Application.put_env(:patchbay, :shots_req_options, old) end)
    shots_answer(200, @picture)
  end

  # The screenshot machine answers every picture asked for with `status`.
  defp shots_answer(status, body) do
    test = self()

    Application.put_env(:patchbay, :shots_req_options,
      plug: fn conn ->
        {:ok, request, conn} = Plug.Conn.read_body(conn)
        send(test, {:shot, Jason.decode!(request)["url"]})
        Plug.Conn.send_resp(conn, status, body)
      end
    )
  end

  defp post!(site) do
    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: "How do I use this site?",
        thread_kind: :help_needed,
        body_markdown: "Asked on the board."
      },
      authorize?: false
    )
  end

  defp run_jobs do
    Oban.drain_queue(queue: :site_checks)
    Oban.drain_queue(queue: :site_pictures, with_scheduled: true, with_recursion: true)
  end

  test "a first post records the page's tools and takes the picture" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")

    post!(site)
    run_jobs()

    assert_received {:shot, "https://example.com/"}

    assert [%{name: "search_docs", address: "https://example.com/"}] =
             Forum.list_tools_for_site!(site.id).results

    assert {:ok, %{image: @picture}} = Forum.get_site_screenshot(site.id)

    # A later post takes no second picture.
    post!(site)
    run_jobs()
    refute_received {:shot, _}
  end

  test "a site without tools gets its picture too" do
    PageSite.serve(%{"/" => PageSite.without_tools()})
    site = Forum.register_site!("plain.example.com")

    post!(site)
    run_jobs()

    assert_received {:shot, "https://example.com/"}
    assert {:ok, _picture} = Forum.get_site_screenshot(site.id)
  end

  test "a picture is tried three times, then again a day later" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    shots_answer(503, "away")

    post!(site)
    run_jobs()

    for _try <- 1..3, do: assert_received({:shot, _})
    refute_received {:shot, _}
    assert {:error, _missing} = Forum.get_site_screenshot(site.id)

    shots_answer(200, @picture)
    post!(site)
    run_jobs()
    refute_received {:shot, _}

    Patchbay.Repo.query!(
      "UPDATE forum_sites SET picture_failed_at = now() - interval '25 hours' WHERE id = $1",
      [Ecto.UUID.dump!(site.id)]
    )

    post!(site)
    run_jobs()

    assert_received {:shot, "https://example.com/"}
    assert {:ok, %{image: @picture}} = Forum.get_site_screenshot(site.id)
  end

  # Regression: a page that blocks screenshot bots (403) was asked three times
  # and each refusal was saved as one of Patchbay's own errors.
  test "a page that refuses the picture is asked once, and its card shows none for a day" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    post!(site)
    run_jobs()
    assert_received {:shot, _}
    assert {:ok, _picture} = Forum.get_site_screenshot(site.id)

    shots_answer(422, Jason.encode!(%{page_status: 403}))

    Patchbay.Repo.query!(
      "UPDATE forum_sites SET screenshot_captured_at = now() - interval '8 days' WHERE id = $1",
      [Ecto.UUID.dump!(site.id)]
    )

    assert %{failure: 0} = schedule_and_run_triggers({Site, :take_picture})
    assert_received {:shot, "https://example.com/"}
    refute_received {:shot, _}

    assert {:error, _forgotten} = Forum.get_site_screenshot(site.id)
    {:ok, refused} = Forum.get_site_by_origin("example.com", authorize?: false)
    assert refused.screenshot_path == nil
    assert refused.picture_failed_at

    assert %{failure: 0} = schedule_and_run_triggers({Site, :take_picture})
    refute_received {:shot, _}
  end

  test "a page that asks us to slow down is asked once and keeps its earlier picture" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    post!(site)
    run_jobs()
    assert_received {:shot, _}

    shots_answer(422, Jason.encode!(%{page_status: 429}))

    Patchbay.Repo.query!(
      "UPDATE forum_sites SET screenshot_captured_at = now() - interval '8 days' WHERE id = $1",
      [Ecto.UUID.dump!(site.id)]
    )

    assert %{failure: 0} = schedule_and_run_triggers({Site, :take_picture})
    assert_received {:shot, "https://example.com/"}
    refute_received {:shot, _}

    assert {:ok, %{image: @picture}} = Forum.get_site_screenshot(site.id)
    {:ok, slowed} = Forum.get_site_by_origin("example.com", authorize?: false)
    assert slowed.screenshot_path
    assert slowed.picture_failed_at
  end

  test "the daily refresh verifies a source again only while it still mentions WebMCP" do
    Catalog.sync!()

    PageSite.serve(%{
      "/docs/api/web-mcp" => "<html><body>Storefronts can offer WebMCP tools.</body></html>",
      "/webmcp-challenge/" => {404, [], "gone"}
    })

    started = DateTime.utc_now()
    listed = Enum.find(Catalog.entries(), &(&1.slug == "netlify")).last_verified_at

    assert %{failure: 0} = schedule_and_run_triggers({Site, :refresh})

    {:ok, shopify} = Forum.get_site_by_origin("shopify.com", authorize?: false)
    {:ok, netlify} = Forum.get_site_by_origin("netlify.com", authorize?: false)

    assert DateTime.compare(shopify.last_verified_at, started) != :lt
    assert DateTime.compare(netlify.last_verified_at, listed) == :eq
    assert shopify.refreshed_at && netlify.refreshed_at

    # Refreshed today, so the next hour's look leaves it alone.
    assert %{failure: 0} = schedule_and_run_triggers({Site, :refresh})
    {:ok, again} = Forum.get_site_by_origin("shopify.com", authorize?: false)
    assert again.refreshed_at == shopify.refreshed_at
  end

  test "a check names what the site publishes and marks which code comes from it" do
    PageSite.serve(%{
      "/" => PageSite.with_tool("search_docs"),
      "/llms.txt" => {200, [{"content-type", "text/plain"}], "# Example\n"},
      # A site that answers every address with its app's page has no such file.
      "/skill.md" => {200, [{"content-type", "text/html"}], "<html>app</html>"}
    })

    OutsideLists.answer(:github, 200, %{
      "items" => [
        %{
          "full_name" => "example/sdk",
          "html_url" => "https://github.com/example/sdk",
          "homepage" => "https://docs.example.com"
        },
        %{"full_name" => "someone/example", "html_url" => "https://github.com/someone/example"}
      ]
    })

    OutsideLists.answer(:npm, 429, %{})

    findings = SiteScan.findings("example.com", Application.get_env(:patchbay, :assist_target))

    assert %{"page_url" => "https://example.com/", "webmcp" => [%{"name" => "search_docs"}]} =
             findings

    assert [%{"kind" => "llms_txt"}] = findings["files"]
    assert findings["servers"] == []

    assert [
             %{"name" => "example/sdk", "from_site" => true},
             %{"name" => "someone/example", "from_site" => false}
           ] = findings["code"]

    assert findings["unsearched"] == ["npm"]
  end
end
