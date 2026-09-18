defmodule PatchbayWeb.AgentReadinessTest do
  @moduledoc """
  What an agent that has never seen Patchbay can rely on: a missing address
  answers in the caller's own format with a way out, every page answers as
  markdown, the machine-readable files describe what is actually there, and
  the pages that say who runs the site exist and say enough.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum

  @contract String.duplicate("a", 64)

  defp site!(origin), do: Forum.register_site!(origin)

  defp tool!(site) do
    Forum.observe_tool!(%{site_id: site.id, name: "checkout", contract_sha256: @contract})
  end

  defp report!(tool) do
    Forum.file_report!(%{
      tool_id: tool.id,
      browser_session_id: Ash.UUID.generate(),
      arguments_sha256: String.duplicate("c", 64),
      verdict: :verified_success,
      note: "Checkout worked | once the cart had an item"
    })
  end

  defp markdown(conn, path) do
    conn = conn |> put_req_header("accept", "text/markdown") |> get(path)
    assert response_content_type(conn, :md) =~ "text/markdown"
    assert "accept" in get_resp_header(conn, "vary")
    {conn.status, conn.resp_body}
  end

  describe "a missing address" do
    test "answers a browser with the styled page and links out of it", %{conn: conn} do
      conn = get(conn, "/no-such-page")

      html = html_response(conn, 404)
      assert html =~ "There is nothing at this address."
      assert html =~ ~s(href="/developers")
      assert html =~ ~s(href="/sitemap.xml")
    end

    test "answers a markdown reader with a markdown map", %{conn: conn} do
      assert {404, body} = markdown(conn, "/no-such-page")
      assert body =~ "# There is nothing at this address."
      assert body =~ "[OpenAPI description](/openapi.json)"
      assert body =~ "[Agent guide](/llms.txt)"
    end

    test "answers an API caller with the JSON error shape whatever it accepts", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/html") |> get("/api/no-such-endpoint")

      assert %{"error" => _, "problem_code" => "not_found", "hint" => hint} =
               json_response(conn, 404)

      assert hint =~ "/openapi.json"
    end

    test "answers a JSON reader anywhere with the JSON error shape", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/no-such-page")
      assert %{"problem_code" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "markdown negotiation" do
    test "the front page and directory answer as markdown", %{conn: conn} do
      site = site!("shop.example")
      report!(tool!(site))

      assert {200, home} = markdown(conn, "/")
      assert home =~ "# Patchbay"
      assert home =~ "[shop.example](/sites/shop-example)"
      assert home =~ "- [Checkout worked | once the cart had an item](/posts/"
      assert home =~ "\n\n---\n\nPatchbay answers every page as markdown"

      assert {200, sites} = markdown(conn, "/sites")
      assert sites =~ "| [shop.example](/sites/shop-example) |"
    end

    test "a site, a tool and a post answer as markdown", %{conn: conn} do
      site = site!("shop.example")
      tool = tool!(site)
      report = report!(tool)

      assert {200, site_md} = markdown(conn, "/sites/shop-example")
      assert site_md =~ "# shop.example"
      assert site_md =~ "| --- |\n| [checkout](/sites/shop-example/tools/checkout) |"

      assert {200, tool_md} = markdown(conn, "/sites/shop-example/tools/checkout")
      assert tool_md =~ "# checkout on shop.example"
      assert tool_md =~ "`#{@contract}`"

      assert {200, post_md} = markdown(conn, "/posts/#{report.id}")
      assert post_md =~ "# Checkout worked | once the cart had an item"
      assert post_md =~ "`GET /forum/threads/#{report.id}`"
      assert post_md =~ "## Evidence"
    end

    test "the fixed pages answer as markdown and a browser still gets HTML", %{conn: conn} do
      for path <-
            ~w(/start /agent-setup /ask /questions /priority /inbox /blog /developers /about /contact /privacy) do
        assert {200, body} = markdown(conn, path)
        assert String.starts_with?(body, "# "), "#{path} did not start with a heading"
      end

      conn = conn |> put_req_header("accept", "text/html,*/*;q=0.8") |> get("/")
      assert html_response(conn, 200) =~ "<!DOCTYPE html>"
      assert "accept" in get_resp_header(conn, "vary")
    end

    test "a room stays a page", %{conn: conn} do
      room = Patchbay.Patchbay.create_seeded_room!("md-#{System.unique_integer([:positive])}")

      assert_raise Phoenix.NotAcceptableError, fn ->
        conn |> put_req_header("accept", "text/markdown") |> get("/webmcp/rooms/#{room.slug}")
      end
    end
  end

  describe "machine-readable files" do
    test "openapi.json describes only routes the router has, each with one operation id", %{
      conn: conn
    } do
      spec = conn |> get("/openapi.json") |> json_response(200)
      assert spec["openapi"] == "3.1.0"
      assert spec["servers"] == [%{"url" => "https://patchbay.help"}]

      operations =
        for {path, methods} <- spec["paths"], {method, op} <- methods do
          route = String.replace(path, ~r/\{[a-z_]+\}/, "x")
          verb = method |> String.upcase()

          assert %{plug: _} =
                   Phoenix.Router.route_info(PatchbayWeb.Router, verb, route, "patchbay.help"),
                 "#{verb} #{path} is in openapi.json but not in the router"

          assert is_binary(op["operationId"]) and is_binary(op["description"])
          op["operationId"]
        end

      assert operations == Enum.uniq(operations)
      assert length(operations) >= 25

      assert get_in(spec, ["components", "schemas", "Error", "required"]) == [
               "error",
               "problem_code"
             ]
    end

    test "sitemap.xml lists the fixed pages, sites, tools and posts with last-change times", %{
      conn: conn
    } do
      site = site!("shop.example")
      tool = tool!(site)
      report = report!(tool)

      url = PatchbayWeb.Endpoint.url()
      conn = get(conn, "/sitemap.xml")
      assert response_content_type(conn, :xml) =~ "application/xml"
      xml = response(conn, 200)

      assert xml =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      assert xml =~ "<loc>#{url}/developers</loc>"
      assert xml =~ "<loc>#{url}/sites/shop-example</loc><lastmod>"

      assert xml =~
               "<loc>#{url}/sites/shop-example/tools/checkout</loc><lastmod>#{DateTime.to_iso8601(tool.last_seen_at)}</lastmod>"

      assert xml =~ "<loc>#{url}/posts/#{report.id}</loc><lastmod>"
    end

    test "robots.txt names the sitemap and llms.txt says when to use Patchbay", %{conn: conn} do
      assert response(get(conn, "/robots.txt"), 200) =~
               "Sitemap: https://patchbay.help/sitemap.xml"

      guide = response(get(conn, "/llms.txt"), 200)
      assert guide =~ "## When to use Patchbay"
      assert guide =~ "/openapi.json"
      assert guide =~ "/developers"
    end
  end

  describe "the document head" do
    test "carries a canonical address, a share image and structured data", %{conn: conn} do
      url = PatchbayWeb.Endpoint.url()
      html = conn |> get("/sites") |> html_response(200)

      assert html =~ ~s(<link rel="canonical" href="#{url}/sites">)
      assert html =~ ~s(<meta property="og:url" content="#{url}/sites">)
      assert html =~ ~s(<meta property="og:title" content="Sites · Patchbay">)

      assert html =~
               ~s(<meta property="og:image" content="#{url}/images/og-image.png">)

      assert File.exists?(Path.join(:code.priv_dir(:patchbay), "static/images/og-image.png"))

      [json] =
        Regex.run(
          ~r{<script type="application/ld\+json" nonce="[^"]+">\s*(.*?)\s*</script>}s,
          html,
          capture: :all_but_first
        )

      %{"@graph" => [application, organization]} = Jason.decode!(json)

      assert application["@type"] == "SoftwareApplication"
      assert application["name"] == "Patchbay"
      assert organization["@type"] == "Organization"
      assert organization["contactPoint"]["email"] == "build@regents.sh"
      refute Map.has_key?(organization, "address")
    end
  end

  describe "the trust pages" do
    test "each exists, is reachable from the footer, and says enough", %{conn: conn} do
      footer = conn |> get("/") |> html_response(200)
      for path <- ~w(/help /about /privacy), do: assert(footer =~ ~s(href="#{path}"))

      assert conn |> get("/help") |> html_response(200) =~ ~s(href="/developers")
      assert conn |> get("/about") |> html_response(200) =~ ~s(href="/contact")

      for path <- ~w(/about /contact /privacy /developers) do
        html = conn |> get(path) |> html_response(200)
        text = html |> Floki.parse_document!() |> Floki.find("main") |> Floki.text()
        assert String.length(text) >= 500, "#{path} has fewer than 500 characters of copy"
      end

      assert conn |> get("/contact") |> html_response(200) =~ "build@regents.sh"
      developers = conn |> get("/developers") |> html_response(200)
      assert developers =~ ~s(href="/openapi.json")

      money =
        developers
        |> Floki.parse_document!()
        |> Floki.find("#webmcp table tbody tr")
        |> Enum.map(fn row -> row |> Floki.find("td") |> Enum.map(&Floki.text/1) end)
        |> Map.new(fn [name, _, _, money, _] -> {name, money} end)

      assert money["search_threads"] == "None"
      assert money["tip_agent"] == "Moves USDC"
      assert redirected_to(get(conn, "/docs")) == "/developers"
    end
  end
end
