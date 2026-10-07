defmodule Patchbay.Forum.SiteCheckTest do
  @moduledoc """
  A site's first post adds it to the directory: its check records the
  page's tools, a picture is taken, and a site with tools joins the gallery.
  A picture that fails is tried three times, and the next post asks again,
  so an outage of the screenshot machine leaves no site without a card for
  good. A check names only what is real, and says which code and packages
  come from the site and which only share its name.
  """

  use Patchbay.DataCase, async: false

  @moduletag :capture_log

  alias Patchbay.Forum
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
    Forum.ask_question!(%{
      site_id: site.id,
      browser_session_id: Ash.UUID.generate(),
      title: "How do I use this site?",
      body_markdown: "Asked on the board."
    })
  end

  defp run_jobs do
    Oban.drain_queue(queue: :site_checks)
    Oban.drain_queue(queue: :site_pictures, with_scheduled: true, with_recursion: true)
  end

  defp gallery_ids, do: Enum.map(Forum.list_gallery_sites!().results, & &1.id)

  test "a first post records the page's tools, takes the picture and puts a site with tools in the gallery" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    refute site.id in gallery_ids()

    post!(site)
    run_jobs()

    assert_received {:shot, "https://example.com/"}

    assert [%{name: "search_docs", address: "https://example.com/"}] =
             Forum.list_tools_for_site!(site.id).results

    assert {:ok, %{image: @picture}} = Forum.get_site_screenshot(site.id)
    assert site.id in gallery_ids()

    # A later post takes no second picture.
    post!(site)
    run_jobs()
    refute_received {:shot, _}
  end

  test "a site without tools gets its picture and stays off the gallery" do
    PageSite.serve(%{"/" => PageSite.without_tools()})
    site = Forum.register_site!("plain.example.com")

    post!(site)
    run_jobs()

    assert_received {:shot, "https://example.com/"}
    assert {:ok, _picture} = Forum.get_site_screenshot(site.id)
    refute site.id in gallery_ids()
  end

  test "a picture is tried three times, and the next post asks again" do
    PageSite.serve(%{"/" => PageSite.with_tool("search_docs")})
    site = Forum.register_site!("docs.example.com")
    shots_answer(503, "away")

    post!(site)
    run_jobs()

    for _try <- 1..3, do: assert_received({:shot, _})
    refute_received {:shot, _}
    refute site.id in gallery_ids()

    shots_answer(200, @picture)
    post!(site)
    run_jobs()

    assert_received {:shot, "https://example.com/"}
    assert site.id in gallery_ids()
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
