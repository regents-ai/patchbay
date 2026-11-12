defmodule Patchbay.Forum.ToolCurrentTest do
  @moduledoc """
  A tool stays on a site's list while the site still offers it. On a site
  with a published list, that list decides. On a site without one, a check
  retires a tool an earlier check found on the page it reads and this one
  did not, but only when it read the whole page, every script on the site's
  own domain included, and found at least one tool on it. A tool known only
  from what agents saw is never retired, a retired tool seen again is offered
  again, and nothing is retired after a failed or partial read, or one that
  found no tools. A site in the researched directory keeps its own list.
  """

  use Patchbay.DataCase, async: false

  alias Patchbay.Forum
  alias Patchbay.PageSite
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest

  @page "https://example.com/"

  setup do
    %{site: Forum.register_site!("example.com")}
  end

  test "a tool a check found and no longer finds is retired, with its time, until it is seen again",
       %{site: site} do
    real_check!(%{"/" => PageSite.with_tool("book") <> PageSite.with_tool("search_docs")})
    assert current(site) == ["book", "search_docs"]
    assert %{retired_at: nil, check_found_at: %DateTime{}} = tool(site, "book")

    before = DateTime.utc_now()
    real_check!(%{"/" => PageSite.with_tool("search_docs")})

    assert current(site) == ["search_docs"]
    assert tool_count(site) == 1
    assert %{retired_at: %DateTime{} = retired_at} = tool(site, "book")
    assert DateTime.compare(retired_at, before) != :lt
    assert %{retired_at: nil} = tool(site, "search_docs")

    # A later check does not move the time it was retired.
    real_check!(%{"/" => PageSite.with_tool("search_docs")})
    assert tool(site, "book").retired_at == retired_at

    seen!(site, "book", @page)
    assert current(site) == ["book", "search_docs"]
    assert tool_count(site) == 2
    assert %{retired_at: nil} = tool(site, "book")
  end

  test "a tool known only from what agents saw survives a whole read that does not find it", %{
    site: site
  } do
    seen!(site, "book", @page)
    real_check!(%{"/" => PageSite.with_tool("search_docs")})

    assert current(site) == ["book", "search_docs"]
    assert %{retired_at: nil, check_found_at: nil} = tool(site, "book")
  end

  test "a tool a check found, since seen on another page, stays", %{site: site} do
    real_check!(%{"/" => PageSite.with_tool("book") <> PageSite.with_tool("search_docs")})
    seen!(site, "book", "https://example.com/orders", description: "The book tool.")

    real_check!(%{"/" => PageSite.with_tool("search_docs")})
    assert current(site) == ["book", "search_docs"]
  end

  test "the check keeps the page it read and when it read it whole", %{site: site} do
    real_check!(%{"/" => PageSite.with_tool("search_docs")})
    {:ok, check} = Forum.get_site_check("example.com")

    assert check.page_url == @page
    assert check.page_read_at == check.checked_at
    refute Map.has_key?(check.findings, "page_url")

    # A script that does not answer: the page is read, but not whole.
    app = ~s(<script src="/app.js"></script>)
    real_check!(%{"/" => PageSite.with_tool("search_docs") <> app, "/app.js" => {503, [], ""}})
    {:ok, check} = Forum.get_site_check("example.com")

    assert check.page_url == @page
    assert is_nil(check.page_read_at)
    assert current(site) == ["search_docs"]
  end

  test "a check that could not read one of the page's scripts retires nothing", %{site: site} do
    real_check!(%{"/" => PageSite.with_tool("book")})
    app = ~s(<script src="/app.js"></script>)

    # The only script answers 503 and the page shows no tools.
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
    real_check!(%{"/" => PageSite.with_tool("book")})

    real_check!(%{"/" => PageSite.without_tools()})
    assert current(site) == ["book"]
  end

  test "a check that could not be done retires nothing and reads no page whole", %{site: site} do
    real_check!(%{"/" => PageSite.with_tool("book") <> PageSite.with_tool("search_docs")})

    {:ok, check} = Forum.get_site_check("example.com")
    Ash.update!(check, %{}, action: :give_up, authorize?: false)

    {:ok, check} = Forum.get_site_check("example.com")
    assert is_nil(check.page_read_at)
    assert current(site) == ["book", "search_docs"]
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

    assert current(site) == ["search"]

    seen!(site, "book", @page)
    assert current(site) == ["book", "search"]
  end

  # An agent's sighting of a tool. With a description, it is the very
  # contract a check records for a page's tool of that name and description.
  defp seen!(site, name, address, opts \\ []) do
    description = opts[:description]
    contract = %{"name" => name, "title" => nil, "description" => description}

    Forum.observe_tool!(%{
      site_id: site.id,
      address: address,
      name: name,
      description: description,
      contract_sha256: contract |> CanonicalJSON.encode() |> Digest.sha256()
    })
  end

  defp tool(site, name) do
    site.id
    |> Forum.tool_history!(name, page: [limit: 1])
    |> Map.fetch!(:results)
    |> hd()
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

  defp current(site) do
    site.id |> Forum.site_inventory!() |> Map.fetch!(:results) |> Enum.map(& &1.name)
  end

  defp tool_count(site) do
    {:ok, loaded} = Forum.get_site_by_origin(site.origin, load: [:tool_count])
    loaded.tool_count
  end
end
