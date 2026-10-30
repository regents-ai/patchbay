defmodule PatchbayWeb.PageReadsTest do
  # A site's page reads the site and its check once: its two live panels draw
  # first from the page's own reads. Each panel reads them itself when it
  # joins, and the check panel reads one page of tools, or none for a site
  # with no tools. When that page is the whole list, it answers which tools
  # the check found are on the list without asking again.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum

  setup do
    site = Forum.register_site!("reads.example")
    list_tool(site, "checkout")
    %{site: site}
  end

  # The first visit asks for a check of the site, which saves it, so the reads
  # are counted on the next visit.
  test "the page reads its site and its check once", %{conn: conn} do
    conn |> get("/reads.example") |> html_response(200)
    reads = reads_during(fn -> conn |> get("/reads.example") |> html_response(200) end)

    assert Enum.count(reads, &(&1 == "forum_sites")) == 1
    assert Enum.count(reads, &(&1 == "site_checks")) == 1
  end

  test "the check panel reads the site, its check and one page of tools", %{conn: conn} do
    find_tools(["checkout", "search_docs"])
    page = conn |> get("/reads.example") |> html_response(200)

    assert reads_on_join(conn, page, PatchbayWeb.SiteCheckLive) == %{
             nil => 1,
             "forum_sites" => 1,
             "site_checks" => 1
           }
  end

  test "the check panel of a site with no tools reads no tools", %{conn: conn} do
    Forum.register_site!("no-tools.example")
    page = conn |> get("/no-tools.example") |> html_response(200)

    assert reads_on_join(conn, page, PatchbayWeb.SiteCheckLive) == %{
             "forum_sites" => 1,
             "site_checks" => 1
           }
  end

  test "the refresh panel reads the site and its check", %{conn: conn} do
    page = conn |> get("/reads.example") |> html_response(200)

    assert reads_on_join(conn, page, PatchbayWeb.SiteRefreshLive) == %{
             "forum_sites" => 1,
             "site_checks" => 1
           }
  end

  test "the check panel shows each tool once when its one page is the whole list", %{
    conn: conn
  } do
    find_tools(["checkout", "search_docs"])

    assert conn |> get("/reads.example") |> tool_rows() == ["search_docs", "checkout"]
  end

  test "the check panel shows each tool once when the list runs past its first page", %{
    conn: conn,
    site: site
  } do
    for n <- 10..29, do: list_tool(site, "tool_#{n}")
    find_tools(["search_docs", "tool_29"])

    rows = conn |> get("/reads.example") |> tool_rows()

    assert hd(rows) == "search_docs"
    assert length(rows) == 21
    refute "tool_29" in rows
  end

  # The tool names the check panel lists, in order.
  defp tool_rows(page) do
    page
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("#pb-site-tools .pb-tool-row-name")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp list_tool(site, name) do
    Forum.observe_tool!(%{
      site_id: site.id,
      address: "https://#{site.origin}/",
      name: name,
      contract_sha256: String.duplicate("a", 64)
    })
  end

  # A finished check of the site that found `names` on its front page.
  defp find_tools(names) do
    findings = %{
      "page_url" => "https://reads.example/",
      "webmcp" => Enum.map(names, &%{"name" => &1}),
      "servers" => [],
      "files" => [],
      "code" => [],
      "unsearched" => []
    }

    check = Forum.request_site_check!("reads.example")
    Forum.record_site_check!(check, %{findings: findings}, authorize?: false)
  end

  # The tables `view`, as drawn on `page`, reads for one draw of its own. A
  # live_isolated mount draws twice, once before it connects and once after,
  # and neither has the page's reads, so each table counts half.
  defp reads_on_join(conn, page, view) do
    session =
      page
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-phx-session]")
      |> LazyHTML.attribute("data-phx-session")
      |> Enum.map(&Phoenix.LiveView.Static.verify_token(PatchbayWeb.Endpoint, &1))
      |> Enum.find_value(fn
        {:ok, %{view: ^view, session: session}} -> session
        _other -> nil
      end)

    conn
    |> then(
      &reads_during(fn -> {:ok, _view, _html} = live_isolated(&1, view, session: session) end)
    )
    |> Enum.frequencies()
    |> Map.new(fn {table, count} -> {table, div(count, 2)} end)
  end

  # The tables read while `request` runs, by any process, in the order read.
  defp reads_during(request) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measurements, %{source: source}, _config -> send(test, {:read, source}) end,
      nil
    )

    request.()
    :telemetry.detach(id)
    collect([])
  end

  defp collect(reads) do
    receive do
      {:read, source} -> collect([source | reads])
    after
      0 -> Enum.reverse(reads)
    end
  end
end
