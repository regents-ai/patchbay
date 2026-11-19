defmodule PatchbayWeb.Forum.SiteStatusTest do
  @moduledoc """
  A site's page says one thing about its tools at a time. Text readers get the
  For agents count alone, never the words it is not showing. The status says
  when Patchbay last checked the site, by that check's own clock, and the
  page and its Markdown give no other time for a check. Before a check has
  finished, the site is not checked, whatever the researched directory lists.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.Catalog

  # A researched-directory site: the directory lists tools for it, and its
  # count is still only what Patchbay's check found.
  @domain "bitdefender.com"
  @iso ~r/[Cc]hecked:? (\d{4}-\d\d-\d\dT[\d:.]+Z)/

  setup do
    Catalog.sync!()
    :ok
  end

  # A check of the site that finished and found two tools on its front page,
  # recorded as Patchbay's check records it.
  defp checked! do
    {:ok, check} = Forum.request_site_check(@domain)

    tools = [
      %{"name" => "scan_url", "description" => "Scans an address."},
      %{"name" => "renew", "description" => "Renews a plan."}
    ]

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(
      check,
      %{
        findings: %{"webmcp" => tools, "servers" => [], "files" => [], "directory" => %{}},
        page_url: "https://" <> @domain <> "/"
      },
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

    assert squish(LazyHTML.text(count)) == "Agents see 2 WebMCP Tools"
    assert LazyHTML.attribute(count, "title") == [squish(LazyHTML.text(count))]
    assert text(html, "#pb-site-standing") =~ "2 tools"
    refute text(html, "main") =~ ~r/Looking for WebMCP tools|Not checked/i
    refute markdown(conn) =~ ~r/Looking for WebMCP tools|Not checked|Checking/i
  end

  test "the status gives the check's own time", %{conn: conn} do
    check = checked!()
    at = DateTime.to_iso8601(check.checked_at)
    html = page(conn)
    standing = LazyHTML.query(html, "#pb-site-standing")

    assert LazyHTML.attribute(LazyHTML.query(standing, "time"), "datetime") == [at]
    refute squish(LazyHTML.text(standing)) =~ ~r/last seen/i

    # Every check time on the page is that check's.
    assert html
           |> LazyHTML.query("#pb-site-standing time, #pb-site-agents time")
           |> LazyHTML.attribute("datetime")
           |> Enum.uniq() == [at]

    markdown = markdown(conn)
    [status] = Regex.run(~r/## Status\n\n(.+)\n/, markdown, capture: :all_but_first)
    assert status =~ at
    assert status =~ "2 tools"

    assert @iso |> Regex.scan(markdown, capture: :all_but_first) |> List.flatten() |> Enum.uniq() ==
             [at]
  end

  test "the directory and a board each lead once to their own WebMCP guide" do
    main = build_conn()

    for conn <- [main, on_open(main)] do
      assert conn |> get("/webmcp") |> html_response(200)

      for path <- ["/sites", "/" <> @domain] do
        html = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
        assert html |> LazyHTML.query("main a[href='/webmcp']") |> Enum.count() == 1, path

        markdown = conn |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)
        assert markdown =~ "](/webmcp)", path
      end
    end
  end

  test "before the first check finishes, the site is not checked, with no time", %{conn: conn} do
    html = page(conn)
    standing = LazyHTML.query(html, "#pb-site-standing")

    assert LazyHTML.query(standing, "time") |> Enum.count() == 0
    assert squish(LazyHTML.text(standing)) =~ "Not checked"
    refute squish(LazyHTML.text(standing)) =~ ~r/\d+ tools?/
    refute text(html, ".pb-site-agent-count") =~ ~r/\d/

    markdown = markdown(conn)
    assert Regex.scan(@iso, markdown) == []
    [status] = Regex.run(~r/## Status\n\n(.+)\n/, markdown, capture: :all_but_first)
    assert status =~ "Not checked"
  end
end
