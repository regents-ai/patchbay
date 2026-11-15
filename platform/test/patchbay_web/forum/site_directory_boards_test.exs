defmodule PatchbayWeb.Forum.SiteDirectoryBoardsTest do
  @moduledoc """
  /sites lists every board on which Patchbay's check found a tool, or with a
  public post, next to the directory's own sites: once each, found by its
  search, counted in its totals and pages, with the board's own tool count. A
  board on a domain the directory already lists is that row, and a listed
  site left out after a check found no tools stays out.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.{HiddenSites, SiteDirectory}
  alias Patchbay.SharedReading

  setup do
    on_exit(fn -> SharedReading.delete(HiddenSites.key()) end)
    :ok
  end

  # A finished check of the site that found `names` on its front page,
  # written as Patchbay's check writes it.
  defp checked!(site, names) do
    {:ok, check} = Forum.request_site_check(site.origin)
    tools = Enum.map(names, &%{"name" => &1, "description" => "The #{&1} tool."})

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(
      check,
      %{
        findings: %{"webmcp" => tools, "servers" => [], "files" => [], "directory" => %{}},
        page_url: "https://#{site.origin}/"
      },
      authorize?: false
    )
  end

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp ask!(site) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: "Checkout tool refuses the basket on #{site.origin}",
        thread_kind: :help_needed,
        body_markdown: "The checkout tool answers an empty basket after adding an item."
      },
      authorize?: false
    )
  end

  defp listing(conn, params \\ %{}) do
    conn
    |> put_req_header("accept", "application/json")
    |> get(~p"/sites?#{params}")
    |> json_response(200)
  end

  defp origins(listing), do: Enum.map(listing["sites"], & &1["origin"])

  test "a board with a tool is found by the directory's search, with the board's tool count",
       %{conn: conn} do
    site = Forum.register_site!("keyfleet.ai")
    checked!(site, ["list_fleets", "join_fleet"])

    assert %{"sites" => [row], "pagination" => %{"total" => 1}} =
             listing(conn, %{"q" => "KEYFLEET"})

    assert %{
             "origin" => "keyfleet.ai",
             "host" => "keyfleet.ai",
             "url" => url,
             "website_url" => "https://keyfleet.ai/",
             "category" => nil,
             "tools" => tools,
             "discussions" => 0
           } = row

    assert tools == 2
    assert url =~ ~r{/keyfleet\.ai$}

    assert row["tool_inventory"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
             ~w(join_fleet list_fleets)

    html = conn |> get(~p"/sites?q=keyfleet") |> html_response(200)
    rows = html |> LazyHTML.from_document() |> LazyHTML.query("tr[id='directory-keyfleet.ai']")
    assert Enum.count(rows) == 1
    assert rows |> LazyHTML.query(".pb-directory-count strong") |> LazyHTML.text() == "2"

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(~p"/sites?q=keyfleet")
      |> response(200)

    assert markdown =~ "1 matching sites"
    assert markdown =~ "](https://keyfleet.ai/) | 2 | [0](/keyfleet.ai) |"
  end

  test "a board with a public post and no tools is listed; an empty board is not",
       %{conn: conn} do
    asked = Forum.register_site!("askedonly.example")
    ask!(asked)
    checked!(asked, [])
    Forum.register_site!("emptyboard.example")

    assert [%{"origin" => "askedonly.example", "tools" => 0, "discussions" => 1}] =
             listing(conn, %{"q" => "askedonly"})["sites"]

    assert listing(conn, %{"q" => "emptyboard"})["sites"] == []
  end

  test "a board on a domain the directory lists is that row, not a second one", %{conn: conn} do
    before = listing(conn, %{"q" => "openai"})
    site = Forum.register_site!("openai.com")
    checked!(site, ["search_openai"])
    ask!(site)

    after_board = listing(conn, %{"q" => "openai"})
    assert after_board["pagination"]["total"] == before["pagination"]["total"]
    assert origins(after_board) == origins(before)
    assert Enum.find(after_board["sites"], &(&1["origin"] == "openai.com"))["discussions"] == 1
  end

  test "a listed site left out after a check found no tools stays out with its board",
       %{conn: conn} do
    {:ok, check} = Forum.request_site_check("target.com")

    directory =
      Map.new(SiteDirectory.pages("target.com"), fn url ->
        {url, %{"checked_at" => "2026-10-30T12:00:00Z", "page_url" => url, "tools" => []}}
      end)

    # Patchbay's own job records findings: there is no actor for policies to check.
    Forum.record_site_check!(check, %{findings: %{"directory" => directory}}, authorize?: false)
    :ok = HiddenSites.refresh()
    ask!(Forum.register_site!("target.com"))

    refute "target.com" in origins(listing(conn, %{"q" => "target"}))
  end

  test "boards come after the directory's sites, in its totals and pages, with no category",
       %{conn: conn} do
    before = listing(conn)["pagination"]["total"]
    checked!(Forum.register_site!("keyfleet.ai"), ["list_fleets"])

    %{"pagination" => %{"total" => total, "pages" => pages}} = listing(conn)
    assert total == before + 1

    last = listing(conn, %{"page" => to_string(pages)})
    assert List.last(origins(last)) == "keyfleet.ai"
    refute "keyfleet.ai" in origins(listing(conn, %{"page" => "1"}))

    category = hd(SiteDirectory.categories())
    assert listing(conn, %{"q" => "keyfleet", "category" => category})["sites"] == []
  end

  test "a page reads its boards together, however many it lists", %{conn: conn} do
    one = Forum.register_site!("qzboard1.example")
    checked!(one, ["first_tool"])
    reads_for_one = queries(fn -> listing(conn, %{"q" => "qzboard"}) end)

    for n <- 2..4 do
      "qzboard#{n}.example" |> Forum.register_site!() |> checked!(["tool_#{n}"])
    end

    assert length(listing(conn, %{"q" => "qzboard"})["sites"]) == 4
    assert queries(fn -> listing(conn, %{"q" => "qzboard"}) end) == reads_for_one
  end

  # How many database queries `run` makes.
  defp queries(run) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:patchbay, :repo, :query],
      fn _event, _measure, _meta, _config ->
        send(test, :query)
      end,
      nil
    )

    run.()
    :telemetry.detach(id)
    count_queries(0)
  end

  defp count_queries(count) do
    receive do
      :query -> count_queries(count + 1)
    after
      0 -> count
    end
  end
end
