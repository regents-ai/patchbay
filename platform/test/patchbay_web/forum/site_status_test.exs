defmodule PatchbayWeb.Forum.SiteStatusTest do
  @moduledoc """
  A site's page says one thing about its tools at a time. Text readers get the
  For agents count alone, never the words it is not showing. The status says
  when Patchbay last checked the site, by that check's own clock, and where
  the listed tools came from when that is not the check; the page and its
  Markdown give no other time for a check.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.Catalog

  # A researched-directory site: its tools come from Patchbay's directory.
  @domain "bitdefender.com"
  @iso ~r/[Cc]hecked:? (\d{4}-\d\d-\d\dT[\d:.]+Z)/

  setup do
    Catalog.sync!()
    :ok
  end

  # A check of the site that finished and found nothing on its front page,
  # recorded as Patchbay's check records it.
  defp checked! do
    {:ok, check} = Forum.request_site_check(@domain)

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(
      check,
      %{findings: %{"webmcp" => [], "servers" => [], "files" => [], "directory" => %{}}},
      authorize?: false
    )
  end

  defp page(conn),
    do: conn |> get("/" <> @domain) |> html_response(200) |> LazyHTML.from_document()

  defp markdown(conn),
    do: conn |> put_req_header("accept", "text/markdown") |> get("/" <> @domain) |> response(200)

  defp text(html, selector), do: html |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  test "text readers get the For agents count alone", %{conn: conn} do
    checked!()
    html = page(conn)
    count = LazyHTML.query(html, ".pb-site-agent-count")
    tools = Forum.get_site_by_origin!(@domain, load: [:tool_count]).tool_count

    assert tools > 0
    assert squish(LazyHTML.text(count)) == "Agents see #{tools} WebMCP Tools"
    assert LazyHTML.attribute(count, "title") == [squish(LazyHTML.text(count))]
    refute text(html, "main") =~ ~r/Looking for WebMCP tools|Not checked yet/i
    refute markdown(conn) =~ ~r/Looking for WebMCP tools|Not checked yet|Checking/i
  end

  test "the status gives the check's own time, and where the listed tools came from",
       %{conn: conn} do
    check = checked!()
    at = DateTime.to_iso8601(check.checked_at)
    html = page(conn)
    standing = LazyHTML.query(html, "#pb-site-standing")

    assert LazyHTML.attribute(LazyHTML.query(standing, "time"), "datetime") == [at]
    refute squish(LazyHTML.text(standing)) =~ ~r/last seen/i
    assert squish(LazyHTML.text(standing)) =~ "directory"

    # Every check time on the page is that check's.
    assert html
           |> LazyHTML.query("#pb-site-standing time, #pb-site-agents time")
           |> LazyHTML.attribute("datetime")
           |> Enum.uniq() == [at]

    markdown = markdown(conn)
    [status] = Regex.run(~r/## Status\n\n(.+)\n/, markdown, capture: :all_but_first)
    assert status =~ at
    assert status =~ "directory"

    assert @iso |> Regex.scan(markdown, capture: :all_but_first) |> List.flatten() |> Enum.uniq() ==
             [at]
  end

  test "the directory and a board each lead once to the WebMCP guide, at patchbay.help only" do
    assert build_conn() |> get("/webmcp") |> html_response(200)

    for path <- ["/sites", "/" <> @domain] do
      html = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()
      assert html |> LazyHTML.query("a[href='/webmcp']") |> Enum.count() == 1, path

      markdown =
        build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

      assert markdown =~ "](/webmcp)", path

      refute build_conn() |> on_open() |> get(path) |> html_response(200) =~ "/webmcp", path

      refute build_conn()
             |> on_open()
             |> put_req_header("accept", "text/markdown")
             |> get(path)
             |> response(200) =~ "/webmcp",
             path
    end
  end

  test "before the first check finishes, the status says so, with no time", %{conn: conn} do
    html = page(conn)
    standing = LazyHTML.query(html, "#pb-site-standing")

    assert LazyHTML.query(standing, "time") |> Enum.count() == 0
    assert squish(LazyHTML.text(standing)) =~ ~r/not checked yet/i
    assert text(html, ".pb-site-agent-count") =~ ~r/^Agents see \d+ WebMCP Tools$/

    markdown = markdown(conn)
    assert Regex.scan(@iso, markdown) == []
    [status] = Regex.run(~r/## Status\n\n(.+)\n/, markdown, capture: :all_but_first)
    assert status =~ ~r/not checked yet/i
  end
end
