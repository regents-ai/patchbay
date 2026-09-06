defmodule PatchbayWeb.ForumAPI.ToolControllerTest do
  use PatchbayWeb.ConnCase, async: false
  alias Patchbay.Forum

  test "all versions survive continuation and re-observation", %{conn: conn} do
    site = Forum.register_site!("history.example")

    versions =
      for n <- 1..29 do
        Forum.observe_tool!(%{
          site_id: site.id,
          name: "checkout",
          contract_sha256: Base.encode16(:crypto.hash(:sha256, "version-#{n}"), case: :lower),
          description: "Version #{n}"
        })
      end

    params = %{"origin" => site.origin, "tool_name" => "checkout"}
    first = conn |> get("/forum/tool-history", params) |> json_response(200)
    assert length(first["versions"]) == 25
    assert first["pagination"]["has_more"]
    oldest = hd(versions)
    Forum.observe_tool!(Map.take(oldest, [:site_id, :name, :contract_sha256, :description]))

    second =
      conn
      |> get("/forum/tool-history", Map.put(params, "after", first["pagination"]["next_cursor"]))
      |> json_response(200)

    ids = Enum.map(first["versions"] ++ second["versions"], & &1["id"])
    assert length(ids) == 29
    assert MapSet.new(ids) == MapSet.new(versions, & &1.id)
    refute second["pagination"]["has_more"]
    assert List.last(ids) == oldest.id

    assert conn
           |> get("/forum/tool-history", Map.put(params, "after", "bad"))
           |> json_response(400)

    assert conn
           |> get(
             "/forum/tool-history",
             %{params | "tool_name" => "other"}
             |> Map.put("after", first["pagination"]["next_cursor"])
           )
           |> json_response(400)
  end

  test "full schemas are returned without private resource fields", %{conn: conn} do
    site = Forum.register_site!("schema.example")
    schema = %{"description" => String.duplicate("資料🌳", 5000)}

    tool =
      Forum.publish_catalog_tool!(%{
        site_id: site.id,
        name: "checkout",
        contract_sha256: String.duplicate("a", 64),
        input_schema: schema,
        raw_definition: %{"inputSchema" => schema}
      })

    result =
      conn
      |> get("/forum/tool-history", %{
        "origin" => site.origin,
        "tool_name" => tool.name,
        "limit" => "1"
      })
      |> json_response(200)

    assert [version] = result["versions"]
    assert version["input_schema"] == schema
    assert version["raw_definition"] == %{"inputSchema" => schema}
    refute Map.has_key?(version, "__metadata__")
    refute Map.has_key?(version, "site_id")
    html = conn |> get("/sites/schema.example/tools/checkout") |> html_response(200)
    assert html =~ String.duplicate("資料🌳", 5000)
    assert html =~ ~s(id="tool-schemas")
  end

  test "missing tools and invalid options are distinct", %{conn: conn} do
    site = Forum.register_site!("empty-history.example")
    params = %{"origin" => site.origin, "tool_name" => "checkout"}
    assert conn |> get("/forum/tool-history", params) |> json_response(404)

    assert conn
           |> get("/forum/tool-history", %{params | "origin" => "unknown.example"})
           |> json_response(404)

    for limit <- ["0", "26", "1.5", "x"] do
      assert conn
             |> get("/forum/tool-history", Map.put(params, "limit", limit))
             |> json_response(400)
    end

    assert conn
           |> get("/forum/tool-history", %{params | "tool_name" => "../bad"})
           |> json_response(400)
  end

  test "HTML continuation preserves newest label and cross-page comparisons", %{conn: conn} do
    site = Forum.register_site!("page-history.example")

    versions =
      for n <- 1..27 do
        Forum.observe_tool!(%{
          site_id: site.id,
          name: "checkout",
          contract_sha256: Base.encode16(:crypto.hash(:sha256, "html-#{n}"), case: :lower),
          title: "Revision #{n}"
        })
      end

    first = conn |> get("/sites/page-history.example/tools/checkout") |> html_response(200)
    boundary = Enum.at(versions, 2)

    boundary_html =
      first
      |> LazyHTML.from_document()
      |> LazyHTML.query("#version-#{boundary.id}")
      |> LazyHTML.to_html()

    assert boundary_html =~ "Revision 2</s>"
    assert boundary_html =~ "Revision 3</ins>"
    refute boundary_html =~ "earliest version"

    link =
      first
      |> LazyHTML.from_document()
      |> LazyHTML.query("nav[aria-label='Version history pages'] a")
      |> LazyHTML.attribute("href")
      |> List.last()

    assert link =~ "after="
    second = conn |> get(link) |> html_response(200)
    refute second =~ "Newest recorded"
    assert second =~ hd(versions).contract_sha256
    assert second =~ "Back to newest"

    assert conn
           |> get("/sites/page-history.example/tools/checkout?after=bad")
           |> html_response(400) =~ "expired or is invalid"
  end

  test "tied first sightings and newly inserted versions keep cursor order", %{conn: conn} do
    site = Forum.register_site!("tie-history.example")

    versions =
      for n <- 1..4 do
        Forum.observe_tool!(%{
          site_id: site.id,
          name: "checkout",
          contract_sha256: Base.encode16(:crypto.hash(:sha256, "tie-#{n}"), case: :lower)
        })
      end

    now = DateTime.utc_now()

    for version <- versions do
      Ecto.Adapters.SQL.query!(
        Patchbay.Repo,
        "UPDATE #{Patchbay.Repo.default_prefix()}.forum_tools SET first_seen_at = $1 WHERE id = $2",
        [now, Ecto.UUID.dump!(version.id)]
      )
    end

    params = %{"origin" => site.origin, "tool_name" => "checkout", "limit" => "2"}
    first = conn |> get("/forum/tool-history", params) |> json_response(200)
    cursor = first["pagination"]["next_cursor"]

    Forum.observe_tool!(%{
      site_id: site.id,
      name: "checkout",
      contract_sha256: String.duplicate("f", 64)
    })

    second =
      conn |> get("/forum/tool-history", Map.put(params, "after", cursor)) |> json_response(200)

    assert Enum.map(first["versions"] ++ second["versions"], & &1["id"]) ==
             Enum.sort(Enum.map(versions, & &1.id))

    other = Forum.register_site!("other-history.example")

    assert conn
           |> get(
             "/forum/tool-history",
             %{params | "origin" => other.origin} |> Map.put("after", cursor)
           )
           |> json_response(400)

    assert conn
           |> get("/forum/tool-history", Map.put(params, "after", cursor <> "x"))
           |> json_response(400)
  end
end
