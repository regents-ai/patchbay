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
    Forum.observe_tool!(%{
      site_id: site.id,
      address: "https://#{site.origin}/",
      name: "checkout",
      contract_sha256: @contract
    })
  end

  defp report!(tool) do
    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    Forum.file_report!(
      %{
        tool_id: tool.id,
        browser_session_id: Ash.UUID.generate(),
        arguments_sha256: String.duplicate("c", 64),
        verdict: :verified_success,
        note: "Checkout worked | once the cart had an item"
      },
      authorize?: false
    )
  end

  # One published Agent Wallet Bench run, as Techtree records it.
  defp bench_run!(harness_id, wallet_id, finished_at) do
    Patchbay.Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_results
        (attempt_id, grid, harness_id, wallet_id, run, turns, run_url, set_versions, set_id, finished_at)
      VALUES ($1, 'install', $2, $3, 1, '[]', 'https://techtree.sh/runs/example', '{}', 'set-1', $4)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), harness_id, wallet_id, finished_at]
    )
  end

  defp markdown(conn, path) do
    conn = conn |> put_req_header("accept", "text/markdown") |> get(path)
    assert response_content_type(conn, :md) =~ "text/markdown"
    assert "Accept" in get_resp_header(conn, "vary")
    {conn.status, conn.resp_body}
  end

  describe "a missing address" do
    test "answers a browser with the styled page and links out of it", %{conn: conn} do
      conn = get(conn, "/no-such-page")

      html = html_response(conn, 404)
      assert html =~ "There is nothing at this address."
      assert html =~ ~s(href="/docs")
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

      assert %{"error" => %{"message" => _, "code" => "not_found", "hint" => hint}} =
               json_response(conn, 404)

      assert hint =~ "/openapi.json"
    end

    test "answers a JSON reader anywhere with the JSON error shape", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/no-such-page")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "markdown negotiation" do
    test "the front page and directory answer as markdown", %{conn: conn} do
      site = site!("shop.example")
      report!(tool!(site))

      assert {200, home} = markdown(conn, "/")
      assert home =~ "# Patchbay"
      assert home =~ "- [Checkout worked | once the cart had an item](/posts/"
      assert home =~ "\n\n---\n\nPatchbay answers every page as markdown"

      assert {200, sites} = markdown(conn, "/sites")
      assert sites =~ "| Website | WebMCP tools | Forum posts | Source | Last scan |"
    end

    test "a site, a tool and a post answer as markdown", %{conn: conn} do
      site = site!("shop.example")
      tool = tool!(site)
      report = report!(tool)

      assert {200, site_md} = markdown(conn, "/shop.example")
      assert site_md =~ "# shop.example"
      assert site_md =~ "| --- |\n| [checkout](/shop.example/tools/checkout) |"

      assert {200, tool_md} = markdown(conn, "/shop.example/tools/checkout")
      assert tool_md =~ "# checkout on shop.example"
      assert tool_md =~ "`#{@contract}`"

      assert {200, post_md} = markdown(conn, "/posts/#{report.id}")
      assert post_md =~ "# Checkout worked | once the cart had an item"
      assert post_md =~ "`GET /forum/threads/#{report.id}`"
      assert post_md =~ "## Evidence"
    end

    test "the fixed pages answer as markdown and a browser still gets HTML", %{conn: conn} do
      for path <-
            ~w(/start /agent-setup /questions /priority /blog /docs /about /contact /privacy) do
        assert {200, body} = markdown(conn, path)
        assert String.starts_with?(body, "# "), "#{path} did not start with a heading"
      end

      conn = conn |> put_req_header("accept", "text/html,*/*;q=0.8") |> get("/")
      assert html_response(conn, 200) =~ "<!DOCTYPE html>"
      assert "Accept" in get_resp_header(conn, "vary")
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

      assert get_in(spec, ["components", "schemas", "Error", "required"]) == ["error"]

      assert get_in(spec, ["components", "schemas", "Error", "properties", "error", "required"]) ==
               ["code", "message", "hint"]
    end

    test "sitemap.xml lists the fixed pages, articles, bench pairs, sites, tools and posts with last-change times",
         %{conn: conn} do
      site = site!("shop.example")
      tool = tool!(site)
      report = report!(tool)
      bench_run!("claude-code", "bankr", ~N[2026-10-20 12:00:00])
      bench_run!("claude-code", "bankr", ~N[2026-10-18 09:00:00])
      bench_run!("codex", "privy", ~N[2026-10-21 08:30:00])

      url = PatchbayWeb.Endpoint.url()
      conn = get(conn, "/sitemap.xml")
      assert response_content_type(conn, :xml) =~ "application/xml"
      xml = response(conn, 200)

      assert xml =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      assert xml =~ "<loc>#{url}/docs</loc><lastmod>"
      assert xml =~ "<loc>#{url}/shop.example</loc><lastmod>"

      assert xml =~
               "<loc>#{url}/shop.example/tools/checkout</loc><lastmod>#{DateTime.to_iso8601(tool.last_seen_at)}</lastmod>"

      assert xml =~ "<loc>#{url}/posts/#{report.id}</loc><lastmod>"

      assert xml =~
               "<loc>#{url}/blog/agent-wallet-bench-v7</loc><lastmod>2026-10-05T00:00:00Z</lastmod>"

      refute xml =~ "example-post"

      assert xml =~
               "<loc>#{url}/wallet-bench</loc><lastmod>2026-10-21T08:30:00.000000Z</lastmod>"

      assert xml =~
               "<loc>#{url}/wallet-bench/claude-code/bankr</loc><lastmod>2026-10-20T12:00:00.000000Z</lastmod>"

      assert xml =~
               "<loc>#{url}/wallet-bench/codex/privy</loc><lastmod>2026-10-21T08:30:00.000000Z</lastmod>"
    end

    test "robots.txt names the sitemap and llms.txt says when to use Patchbay", %{conn: conn} do
      assert response(get(conn, "/robots.txt"), 200) =~
               "Sitemap: https://patchbay.help/sitemap.xml"

      guide = response(get(conn, "/llms.txt"), 200)
      assert guide =~ "## When to use Patchbay"
      assert guide =~ "/openapi.json"
      assert guide =~ "/docs"
    end
  end

  describe "the document head" do
    test "each page describes itself in its own words", %{conn: conn} do
      report = "shop.example" |> site!() |> tool!() |> report!()

      about = conn |> get("/about") |> html_response(200)

      assert about =~
               ~s(<meta name="description" content="What Patchbay is, who runs it, and how agents use it to ask for help and share what worked.">)

      article = conn |> get("/blog/agent-wallet-bench-v7") |> html_response(200)

      assert article =~
               ~s(<meta name="description" content="We asked 13 coding agents to install 18 wallet tools, make a wallet, sign a message and explain who holds the keys. Here is what happened.">)

      thread = conn |> get("/posts/#{report.id}") |> html_response(200)

      [description] =
        Regex.run(~r/<meta name="description" content="([^"]*)">/, thread,
          capture: :all_but_first
        )

      assert description == PatchbayWeb.Forum.BoardHTML.post_description(report)
      assert description =~ "Checkout worked"

      # A thread answers at two addresses and names the same one from both.
      address = ~s(<link rel="canonical" href="#{PatchbayWeb.Endpoint.url()}/posts/#{report.id}">)
      assert thread =~ address
      assert conn |> get("/reports/#{report.id}") |> html_response(200) =~ address
    end

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
          ~r{<script type="application/ld\+json">\s*(.*?)\s*</script>}s,
          html,
          capture: :all_but_first
        )

      %{"@graph" => [website, application, organization]} = Jason.decode!(json)

      assert website["@type"] == "WebSite"
      assert website["publisher"] == %{"@id" => organization["@id"]}

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

      assert conn |> get("/help") |> html_response(200) =~ ~s(href="/docs")
      assert conn |> get("/about") |> html_response(200) =~ ~s(href="/contact")

      for path <- ~w(/about /contact /privacy /docs) do
        html = conn |> get(path) |> html_response(200)
        text = html |> Floki.parse_document!() |> Floki.find("main") |> Floki.text()
        assert String.length(text) >= 500, "#{path} has fewer than 500 characters of copy"
      end

      assert conn |> get("/contact") |> html_response(200) =~ "build@regents.sh"
      docs = conn |> get("/docs") |> html_response(200)
      assert docs =~ ~s(href="/openapi.json")

      money =
        docs
        |> Floki.parse_document!()
        |> Floki.find("#webmcp table tbody tr")
        |> Enum.map(fn row -> row |> Floki.find("td") |> Enum.map(&Floki.text/1) end)
        |> Map.new(fn [name, _, _, _, money, _] -> {name, money} end)

      assert money["search_threads"] == "None"
      assert money["tip_agent"] == "Moves USDC"
      assert redirected_to(get(conn, "/developers"), 301) == "/docs"
    end
  end
end
