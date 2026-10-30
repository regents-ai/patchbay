defmodule PatchbayWeb.Forum.SiteDirectoryHidingTest do
  @moduledoc """
  A site whose check read every one of its pages and found no WebMCP tool is
  left out of every listing of sites, with the totals, until a check finds
  one; its own page stays open (PB-65). Listings take the hidden sites from
  one shared reading (`Patchbay.Forum.HiddenSites`), reread on each check's
  notice, so a listing never reads them from the database.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.{Catalog, HiddenSites, SiteDirectory}
  alias Patchbay.Repo
  alias Patchbay.SharedReading

  @domain "target.com"
  @host "target.com"

  setup do
    Catalog.sync!()
    on_exit(fn -> SharedReading.delete(HiddenSites.key()) end)
    :ok
  end

  # A finished check of Target's directory pages, each found with `tools`
  # (nil leaves that page unread), and the reread its notice asks for.
  defp checked!(tools_by_page) do
    record_check!(tools_by_page)
    :ok = HiddenSites.refresh()
  end

  defp record_check!(tools_by_page) do
    {:ok, check} = Forum.request_site_check(@domain)

    directory =
      @domain
      |> SiteDirectory.pages()
      |> Enum.zip(tools_by_page)
      |> Map.new(fn
        {url, nil} ->
          {url, %{"failed" => true, "last_attempt_at" => "2026-10-30T12:00:00Z"}}

        {url, tools} ->
          {url,
           %{
             "checked_at" => "2026-10-30T12:00:00Z",
             "page_url" => url,
             "failed" => false,
             "tools" => Enum.map(tools, &%{"name" => &1, "address" => url})
           }}
      end)

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(check, %{findings: %{"directory" => directory}}, authorize?: false)
  end

  # How many times the hidden sites are read from the database while `run` runs.
  defp hidden_reads(run) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ "jsonb_path_exists", do: send(test, :hidden_read)
      end,
      nil
    )

    run.()
    :telemetry.detach(id)
    count_hidden_reads(0)
  end

  defp count_hidden_reads(count) do
    receive do
      :hidden_read -> count_hidden_reads(count + 1)
    after
      0 -> count
    end
  end

  defp listing(conn, params \\ %{}) do
    conn
    |> put_req_header("accept", "application/json")
    |> get(~p"/sites?#{params}")
    |> json_response(200)
  end

  defp hosts(listing), do: Enum.map(listing["sites"], & &1["host"])

  defp sitemap(conn) do
    PatchbayTest.SharedBench.share!()
    conn |> get("/sitemap.xml") |> response(200)
  end

  test "a site a check found no tools on leaves every listing, and its total",
       %{conn: conn} do
    before = listing(conn)
    target = Enum.find(listing(conn, %{"q" => "target"})["sites"], &(&1["host"] == @host))
    assert target
    assert sitemap(conn) =~ "/#{@domain}</loc>"

    checked!([[], []])

    after_check = listing(conn)
    assert after_check["pagination"]["total"] == before["pagination"]["total"] - 1
    refute @host in hosts(after_check)
    refute @host in hosts(listing(conn, %{"q" => "target"}))

    refute @host in hosts(listing(conn, %{"q" => "target", "category" => target["category"]}))

    refute conn |> get(~p"/sites") |> html_response(200) =~ ~s(id="directory-#{@host}")

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(~p"/sites?q=target")
      |> response(200)

    refute markdown =~ "](https://www.target.com/)"

    refute sitemap(conn) =~ "/#{@domain}</loc>"
  end

  test "the site's own page still opens while it is left out", %{conn: conn} do
    checked!([[], []])

    assert conn |> get("/" <> @domain) |> html_response(200)
  end

  test "a check that finds a tool brings the site back", %{conn: conn} do
    checked!([[], []])
    refute @host in hosts(listing(conn, %{"q" => "target"}))

    checked!([["search_products"], []])

    site = Enum.find(listing(conn, %{"q" => "target"})["sites"], &(&1["host"] == @host))
    assert %{"tools" => 1, "source" => "Source scan"} = site
    assert sitemap(conn) =~ "/#{@domain}</loc>"
  end

  test "a site not yet read on every page stays listed with its reported tools",
       %{conn: conn} do
    checked!([[], nil])

    site = Enum.find(listing(conn, %{"q" => "target"})["sites"], &(&1["host"] == @host))
    assert %{"source" => "Research listing"} = site
  end

  test "listings read the hidden sites from memory, never from the database", %{conn: conn} do
    checked!([[], []])

    assert 0 ==
             hidden_reads(fn ->
               conn |> get(~p"/sites") |> html_response(200)
               listing(conn)

               conn
               |> put_req_header("accept", "text/markdown")
               |> get(~p"/sites")
               |> response(200)

               sitemap(conn)
             end)
  end

  @tag :capture_log
  test "while site checks cannot be read, listings answer with the last reading",
       %{conn: conn} do
    checked!([[], []])
    total = listing(conn)["pagination"]["total"]

    Repo.query!("ALTER TABLE site_checks RENAME TO site_checks_away")
    assert {:error, _unread} = HiddenSites.refresh()

    after_failure = listing(conn, %{"q" => "target"})
    refute @host in hosts(after_failure)
    assert listing(conn)["pagination"]["total"] == total
    assert conn |> get(~p"/sites") |> html_response(200)
  end

  test "with no reading yet, every site is listed", %{conn: conn} do
    before = listing(conn)["pagination"]["total"]
    checked!([[], []])
    SharedReading.delete(HiddenSites.key())

    assert listing(conn)["pagination"]["total"] == before
    assert @host in hosts(listing(conn, %{"q" => "target"}))
  end

  test "the process rereads once for a burst of check notices" do
    start_supervised!(HiddenSites)

    reads =
      hidden_reads(fn ->
        for _notice <- 1..3, do: record_check!([[], []])
        Process.sleep(1_500)
      end)

    assert reads == 1
    assert @host in HiddenSites.reading().hosts
  end
end
