defmodule Patchbay.Forum.ToolCurrentTest do
  @moduledoc """
  A tool stays on a site's list while the site still offers it. On a site
  with a published list, that list decides. On a site without one, a tool
  last seen on the page Patchbay's check read, and missing from what the
  check found there, is retired until an agent sees it again, but only when
  the check read the whole page, every script on the site's own domain
  included, and found at least one tool on it. A tool seen on another page
  stays, and so does everything after a failed or partial read, or one that
  found no tools. A site in the researched directory keeps its own list.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Forum
  alias Patchbay.PageSite

  @page "https://example.com/"

  setup do
    %{site: Forum.register_site!("example.com")}
  end

  test "a tool missing from the page the check read is retired until it is seen again", %{
    site: site
  } do
    seen!(site, "book", @page)
    seen!(site, "track", "https://example.com/orders")

    checked!(%{"page_url" => @page, "page_complete" => true, "webmcp" => [%{"name" => "search"}]})

    assert current(site) == ["track"]
    assert tool_count(site) == 1

    seen!(site, "book", @page)
    assert current(site) == ["book", "track"]
    assert tool_count(site) == 2
  end

  test "a real check keeps what it found on the page and retires the rest", %{site: site} do
    seen!(site, "book", @page)
    seen!(site, "search_docs", @page)
    real_check!(%{"/" => PageSite.with_tool("search_docs")})

    assert current(site) == ["search_docs"]
  end

  test "a real check that could not read one of the page's scripts retires nothing", %{
    site: site
  } do
    seen!(site, "book", @page)
    app = ~s(<script src="/app.js"></script>)

    # The gate's case: the only script answers 503 and the page shows no tools.
    real_check!(%{"/" => PageSite.without_tools() <> app, "/app.js" => {503, [], "away"}})
    assert current(site) == ["book"]
    assert tool_count(site) == 1

    # The page signs up a tool itself, but its script still went unread.
    real_check!(%{"/" => PageSite.with_tool("search_docs") <> app, "/app.js" => {503, [], ""}})
    assert current(site) == ["book", "search_docs"]
  end

  test "a tool signed up two imports deep stays", %{site: site} do
    seen!(site, "deep_tool", @page)

    # The gate's case: app.js imports a.js, which imports b.js.
    real_check!(%{
      "/" => ~s(<html><body><script type="module" src="/app.js"></script></body></html>),
      "/app.js" => ~s|import "./a.js";\n| <> registers("shallow_tool"),
      "/a.js" => ~s|import "./b.js";\nexport const a = 1;|,
      "/b.js" => registers("deep_tool")
    })

    assert current(site) == ["deep_tool", "shallow_tool"]
  end

  test "a site in the researched directory keeps its own list", %{site: site} do
    verified = ~U[2026-10-01 12:00:00.000000Z]

    Forum.upsert_catalog_entry!("example.com", %{
      support_relationship: :site_tools,
      tool_inventory_status: :observed,
      last_verified_at: verified
    })

    Forum.publish_catalog_tool!(%{
      site_id: site.id,
      address: @page,
      name: "book",
      contract_sha256: String.duplicate("c", 64),
      source_kind: :observed,
      first_seen_at: verified,
      last_seen_at: verified
    })

    seen!(site, "track", @page)

    # The gate's case: the check finds both there, and records neither.
    real_check!(%{"/" => PageSite.with_tool("book") <> PageSite.with_tool("track")})
    assert current(site) == ["book", "track"]
    assert tool_count(site) == 2

    real_check!(%{"/" => PageSite.with_tool("search")})
    assert current(site) == ["book", "track"]
  end

  test "a whole read that found no tools retires nothing", %{site: site} do
    seen!(site, "book", @page)

    real_check!(%{"/" => PageSite.without_tools()})
    assert current(site) == ["book"]
  end

  test "a failed or partial read, one that read no page, or one recorded before reads were marked whole retires nothing",
       %{site: site} do
    seen!(site, "book", @page)
    found = [%{"name" => "search"}]

    for findings <- [
          %{"page_url" => @page, "page_complete" => true, "webmcp" => found, "failed" => true},
          %{"page_url" => @page, "page_complete" => false, "webmcp" => found},
          %{"page_url" => @page, "webmcp" => found},
          %{"page_url" => nil, "page_complete" => false, "webmcp" => []}
        ] do
      checked!(findings)
      assert current(site) == ["book"]
    end
  end

  test "a site with a published list keeps to that list", %{site: site} do
    seen!(site, "book", @page)

    Forum.publish_catalog_tool!(%{
      site_id: site.id,
      address: @page,
      name: "search",
      contract_sha256: String.duplicate("c", 64),
      source_kind: :official,
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    })

    # The page check found "book" there, yet the published list is newer.
    checked!(%{"page_url" => @page, "page_complete" => true, "webmcp" => [%{"name" => "book"}]})
    assert current(site) == ["search"]

    seen!(site, "book", @page)
    assert current(site) == ["book", "search"]
  end

  defp seen!(site, name, address) do
    Forum.observe_tool!(%{
      site_id: site.id,
      address: address,
      name: name,
      contract_sha256: String.duplicate("a", 64)
    })
  end

  # A check through its own job, of a site answering from `pages`.
  defp real_check!(pages) do
    PageSite.serve(pages)
    Forum.refresh_site_check!("example.com")
    Oban.drain_queue(queue: :site_checks)
  end

  # A script that signs up one tool, `name`.
  defp registers(name) do
    ~s|navigator.modelContext.registerTool({name: "#{name}", description: "The #{name} tool.", | <>
      ~s|inputSchema: {type: "object"}, execute: async () => ({})});|
  end

  defp checked!(findings) do
    # What the check's own job writes: only Patchbay records a check.
    check = Forum.request_site_check!("example.com")
    Forum.record_site_check!(check, %{findings: findings}, authorize?: false)
  end

  defp current(site) do
    site.id |> Forum.site_inventory!() |> Map.fetch!(:results) |> Enum.map(& &1.name)
  end

  defp tool_count(site) do
    {:ok, loaded} = Forum.get_site_by_origin(site.origin, load: [:tool_count])
    loaded.tool_count
  end
end
