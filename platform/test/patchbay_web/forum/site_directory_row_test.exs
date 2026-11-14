defmodule PatchbayWeb.Forum.SiteDirectoryRowTest do
  @moduledoc """
  A row on /sites tells people what Patchbay knows about a site, never how
  its checks went: after a read that could not finish, the page, its
  Markdown and its JSON keep the last tools and when Patchbay last read the
  site, with no word of the failure, and none of them names the outside
  directory the site was first listed in. Opened, a row holds the picture
  Patchbay took of the site's home page and its tools' names, nothing else;
  View Forum goes where the row's post count goes. A check that could not be
  done changes nothing on the site's own page either.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.{ListedSitePicture, SiteDirectory}
  alias PatchbayWeb.{LivePart, SiteDirectoryLive}

  @domain "openai.com"
  @read_at "2026-11-10T09:30:00Z"
  @outside ~r/webmcp\.com|directory page/i
  # Listed with no tool names and never checked.
  @no_tools "dogechain.info"

  setup do
    site = Forum.register_site!(@domain)
    incomplete_check!()
    {:ok, site: site}
  end

  # A check that read OpenAI's listed page whole at `@read_at`, then a later
  # read of it that could not finish, written as Patchbay's check writes it.
  defp incomplete_check! do
    {:ok, check} = Forum.request_site_check(@domain)

    directory =
      Map.new(SiteDirectory.pages(@domain), fn page ->
        {page,
         %{
           "checked_at" => @read_at,
           "page_url" => page,
           "tools" => [%{"name" => "search_openai", "address" => page}]
         }}
      end)

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(
      check,
      %{
        findings: %{
          "webmcp" => [%{"name" => "search_openai", "description" => "Search OpenAI's site."}],
          "servers" => [],
          "files" => [],
          "directory" => directory
        }
      },
      authorize?: false
    )
  end

  # What TakeSitePicture records once the screenshot machine has answered;
  # the picture's job is not under test here.
  defp pictured!(site) do
    path = "/site-screenshots/#{site.id}?at=1762000000"

    Ash.update!(site, %{screenshot_path: path, screenshot_captured_at: DateTime.utc_now()},
      action: :record_screenshot,
      authorize?: false
    )

    path
  end

  defp directory(conn, q \\ "openai") do
    session =
      conn
      |> get(~p"/sites?#{[q: q]}")
      |> html_response(200)
      |> LivePart.session(SiteDirectoryLive)

    {:ok, view, _html} = live_isolated(build_conn(), SiteDirectoryLive, session: session)
    view
  end

  # The opened row's panel, as the elements directly inside it.
  defp opened(view, host \\ @domain) do
    view |> element("tr[id='directory-#{host}'] .pb-directory-expand") |> render_click()

    view
    |> element("[id='tools-#{host}']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id='tools-#{host}'] > *")
  end

  defp tags(nodes), do: nodes |> Enum.map(&LazyHTML.tag/1) |> List.flatten()

  defp texts(html, selector),
    do: html |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  test "after a read that could not finish, the page, Markdown and JSON keep the last tools and read",
       %{conn: conn} do
    html = conn |> get(~p"/sites?q=openai") |> html_response(200)
    row = html |> LazyHTML.from_document() |> LazyHTML.query("tr[id='directory-openai.com']")

    refute LazyHTML.text(row) =~ ~r/incomplete|reported/i
    refute html =~ @outside
    assert texts(row, ".pb-directory-tool-list li") == ["search_openai"]

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(~p"/sites?q=openai")
      |> response(200)

    refute markdown =~ @outside
    assert markdown =~ "| Source scan | #{@read_at} |"

    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/sites?q=openai")
      |> json_response(200)

    refute Jason.encode!(body) =~ @outside
    site = Enum.find(body["sites"], &(&1["origin"] == @domain))
    refute Map.has_key?(site, "reported_tool_observation")

    assert %{"verified_at" => @read_at, "source" => "Source scan", "tools" => 1} = site
    assert [%{"name" => "search_openai"}] = site["tool_inventory"]
  end

  test "an opened row holds the site's home page picture and its tool names, and nothing else",
       %{conn: conn, site: site} do
    path = pictured!(site)

    opened = conn |> directory() |> opened()

    assert tags(opened) == ["img", "ul"]
    picture = LazyHTML.query(opened, "img")
    # Patchbay's own copy of the picture, laid out before it loads.
    assert LazyHTML.attribute(picture, "src") == [path]
    assert LazyHTML.attribute(picture, "loading") == ["lazy"]
    assert LazyHTML.attribute(picture, "width") == ["1600"]
    assert LazyHTML.attribute(picture, "height") == ["1000"]
    assert [alt] = LazyHTML.attribute(picture, "alt")
    assert alt =~ "OpenAI"

    # Each tool is its name alone.
    assert texts(opened, "li") == ["search_openai"]
  end

  test "a listed site with no board shows the picture Patchbay took of its home page",
       %{conn: conn} do
    host = "target.com"
    picture = "RIFF" <> <<4::little-32>> <> "WEBP" <> "VP8 "
    old = Application.get_env(:patchbay, :shots_req_options)
    on_exit(fn -> Application.put_env(:patchbay, :shots_req_options, old) end)

    Application.put_env(:patchbay, :shots_req_options,
      plug: &Plug.Conn.send_resp(&1, 200, picture)
    )

    assert :ok =
             Oban.Testing.perform_job(ListedSitePicture.Workers.Take, %{domain: host},
               repo: Patchbay.Repo
             )

    opened = conn |> directory(host) |> opened(host)

    assert tags(opened) == ["img", "ul"]
    assert [path] = opened |> LazyHTML.query("img") |> LazyHTML.attribute("src")
    assert path =~ "/listed-site-pictures/target.com?at="

    served = get(build_conn(), path)
    assert response(served, 200) == picture
    assert response_content_type(served, :webp) =~ "image/webp"
  end

  test "a listed site whose picture failed shows only its tools", %{conn: conn} do
    host = "target.com"
    old = Application.get_env(:patchbay, :shots_req_options)
    on_exit(fn -> Application.put_env(:patchbay, :shots_req_options, old) end)

    Application.put_env(:patchbay, :shots_req_options,
      plug: &Plug.Conn.send_resp(&1, 422, Jason.encode!(%{page_status: 403}))
    )

    assert :ok =
             Oban.Testing.perform_job(ListedSitePicture.Workers.Take, %{domain: host},
               repo: Patchbay.Repo
             )

    assert conn |> directory(host) |> opened(host) |> tags() == ["ul"]
    assert build_conn() |> get("/listed-site-pictures/target.com") |> response(404)
  end

  test "an opened row without a picture holds only the tools, and one without tools says so",
       %{conn: conn} do
    assert conn |> directory() |> opened() |> tags() == ["ul"]

    assert [empty] = conn |> directory(@no_tools) |> opened(@no_tools) |> Enum.to_list()
    assert LazyHTML.tag(empty) == ["p"]
    refute LazyHTML.text(empty) == ""
  end

  test "View Forum goes where the row's post count goes", %{conn: conn} do
    view = directory(conn)

    posts =
      view
      |> element("tr[id='directory-openai.com'] a.pb-directory-posts")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")

    assert posts == ["/openai.com"]

    assert {:error, {:redirect, %{to: "/openai.com"}}} =
             view
             |> element("tr[id='directory-openai.com'] a.pb-directory-forum")
             |> render_click()
  end

  test "a check that could not be done leaves the site's page as the last check left it",
       %{conn: conn} do
    panel = fn ->
      page = conn |> get("/" <> @domain) |> html_response(200) |> LazyHTML.from_document()
      {texts(page, ".pb-site-agent-count [data-on]"), texts(page, ".pb-site-check-status")}
    end

    {count, [status]} = panel.()
    assert status =~ "Checked"

    Forum.refresh_site_check!(@domain)
    {:ok, asked} = Forum.get_site_check(@domain)
    # What the check's job does once its last try has failed.
    Ash.update!(asked, %{}, action: :give_up, authorize?: false)

    assert {^count, [""]} = panel.()
  end
end
