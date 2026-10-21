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

  # The page's schema.org nodes, as a crawler reads them from its head.
  defp structured_data(html) do
    [json] =
      Regex.run(~r{<script type="application/ld\+json">\s*(.*?)\s*</script>}s, html,
        capture: :all_but_first
      )

    Jason.decode!(json)["@graph"]
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
      # Test Me and Ask Jev are previews kept out of every listing.
      refute xml =~ "<loc>#{url}/test-me</loc>"
      refute xml =~ "<loc>#{url}/jev</loc>"
    end

    test "Test Me and Ask Jev are linked from nowhere a reader browses", %{conn: conn} do
      for path <- ~w(/ /help /test-me /jev) do
        html = conn |> get(path) |> html_response(200)
        refute html =~ ~s(href="/test-me")
        refute html =~ ~s(href="/jev")
      end

      pages = for path <- ~w(/help /test-me /jev), do: elem(markdown(conn, path), 1)

      files =
        for path <- ~w(/llms.txt /agents.md /skill.md), do: conn |> get(path) |> response(200)

      for body <- pages ++ files do
        refute body =~ "/test-me"
        refute body =~ "(/jev)"
      end
    end

    test "the five-tool core leads the manifest, llms.txt and the docs page", %{conn: conn} do
      core = ~w(search_threads get_thread ask_question post_reply record_answer_use)

      manifest = conn |> get("/forum/capabilities") |> json_response(200)
      assert manifest["core_tools"] == core
      assert manifest["tools"] |> Enum.take(5) |> Enum.map(& &1["name"]) == core

      guide = response(get(build_conn(), "/llms.txt"), 200)
      assert guide =~ "## Start with five tools"
      assert length(String.split(guide)) < 1_500
      for name <- core, do: assert(guide =~ "| " <> name <> " |")

      html = build_conn() |> get("/docs") |> html_response(200)
      {core_at, _} = :binary.match(html, ~s(id="core-tools"))
      {more_at, _} = :binary.match(html, ~s(id="more-tools"))
      {guide_at, _} = :binary.match(html, ~s(id="agents"))
      assert core_at < more_at and more_at < guide_at
      assert html =~ ~s(id="optional-siwa-verified-hello")

      {_status, md} = markdown(build_conn(), "/docs")
      assert md =~ "### Start with five tools"
      assert md =~ "## More for agents"
      assert md =~ "### Threads over HTTP"
    end

    test "the skill has one header block, one schedule rule and the five tools first", %{
      conn: conn
    } do
      skill = conn |> get("/skill.md") |> response(200)

      assert ["", _header, _body] = String.split(skill, ~r/^---$/m, parts: 3)
      assert length(Regex.scan(~r/^---$/m, skill)) == 2
      assert length(Regex.scan(~r/^## .*schedule/im, skill)) == 1
      refute skill =~ "signed POST"

      [first_section | _] = String.split(skill, ~r/^## /m) |> Enum.drop(1)
      assert first_section =~ "Start with five tools"

      names =
        Regex.scan(~r/^\| `([a-z_]+)` \|/m, first_section, capture: :all_but_first)
        |> List.flatten()

      assert names == ~w(search_threads get_thread ask_question post_reply record_answer_use)
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

      [website, application, organization] = structured_data(html)

      assert website["@type"] == "WebSite"
      assert website["publisher"] == %{"@id" => organization["@id"]}

      assert application["@type"] == "SoftwareApplication"
      assert application["name"] == "Patchbay"
      assert organization["@type"] == "Organization"
      assert organization["contactPoint"]["email"] == "build@regents.sh"
      refute Map.has_key?(organization, "address")
    end
  end

  describe "what a page holds, for search engines and AI answers" do
    test "a thread is a question, named and dated as the page shows it", %{conn: conn} do
      report = "shop.example" |> site!() |> tool!() |> report!()
      html = conn |> get("/reports/#{report.id}") |> html_response(200)

      [_website, _application, _organization, page] = structured_data(html)
      question = page["mainEntity"]

      assert page["@type"] == "QAPage"
      assert page["url"] == "#{PatchbayWeb.Endpoint.url()}/posts/#{report.id}"
      assert question["name"] == PatchbayWeb.Forum.BoardHTML.post_title(report)
      assert question["text"] =~ "once the cart had an item"
      assert question["datePublished"] == DateTime.to_iso8601(report.inserted_at)
      assert question["answerCount"] == 0
      refute Map.has_key?(question, "acceptedAnswer")
    end

    test "an article names its headline, date, cover and publisher", %{conn: conn} do
      url = PatchbayWeb.Endpoint.url()
      html = conn |> get("/blog/agent-wallet-bench-v7") |> html_response(200)

      [_website, _application, organization, article] = structured_data(html)

      assert article["@type"] == "BlogPosting"
      assert article["url"] == "#{url}/blog/agent-wallet-bench-v7"
      assert article["headline"] == PatchbayWeb.Blog.get("agent-wallet-bench-v7").title
      assert article["image"] == "#{url}/images/blog/agent-wallet-bench-v7-t2.svg"
      assert article["publisher"] == %{"@id" => organization["@id"]}
    end

    test "the Agent Wallet Bench is a table of data with its newest run and its JSON" do
      url = PatchbayWeb.Endpoint.url()

      roster = [
        %{id: "H1", kind: "harness", name: "Agent"},
        %{id: "W1", kind: "wallet", name: "Wallet"}
      ]

      run = fn attempt_id, finished_at ->
        %{
          attempt_id: attempt_id,
          grid: "install",
          harness_id: "H1",
          wallet_id: "W1",
          run: 1,
          outcome: "PASS",
          decided_by: nil,
          set_id: "set",
          set_versions: %{},
          finished_at: finished_at
        }
      end

      results = [
        run.(Ash.UUID.generate(), ~U[2026-10-18 09:00:00Z]),
        run.(Ash.UUID.generate(), ~U[2026-10-20 12:00:00Z])
      ]

      summary = %{
        set_id: "set",
        harness_id: "H1",
        wallet_id: "W1",
        current: true,
        last_run_at: ~U[2026-10-20 12:00:00Z]
      }

      dataset =
        Patchbay.WalletBench.Matrix.build(roster, [], [], results, [summary], [])
        |> PatchbayWeb.WalletBenchHTML.dataset()

      assert dataset["@type"] == "Dataset"
      assert dataset["url"] == "#{url}/wallet-bench"
      assert dataset["creator"] == %{"@id" => PatchbayWeb.Layouts.organization_id()}
      assert dataset["dateModified"] == "2026-10-20"

      assert dataset["distribution"] == [
               %{
                 "@type" => "DataDownload",
                 "contentUrl" => "#{url}/api/wallet-bench",
                 "encodingFormat" => "application/json"
               }
             ]

      # An empty board has no newest run, so it names none.
      empty = Patchbay.WalletBench.Matrix.build(roster, [], [], [], [], [])
      refute Map.has_key?(PatchbayWeb.WalletBenchHTML.dataset(empty), "dateModified")
    end

    test "a fixed page carries only the site's own graph", %{conn: conn} do
      html = conn |> get("/about") |> html_response(200)

      assert ["WebSite", "SoftwareApplication", "Organization"] ==
               Enum.map(structured_data(html), & &1["@type"])
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
