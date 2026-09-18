defmodule PatchbayWeb.Forum.DirectoryTest do
  @moduledoc """
  The WebMCP directory slice: catalog grid, site → tool → post, and paid
  placement ranking from settled escrow only.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.{Capabilities, Catalog}
  alias Patchbay.Identity
  alias Patchbay.Patchbay, as: Rooms

  @contract String.duplicate("a", 64)
  @other_contract String.duplicate("b", 64)
  @arguments String.duplicate("c", 64)

  @required_brands ~w(Render Netlify OpenAI Chrome Shopify)

  defp site!(origin), do: Forum.register_site!(origin)

  defp tool!(site, attrs \\ %{}) do
    Forum.observe_tool!(
      Map.merge(%{site_id: site.id, name: "checkout", contract_sha256: @contract}, attrs)
    )
  end

  defp report!(tool, attrs) do
    Forum.file_report!(
      Map.merge(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_success
        },
        attrs
      )
    )
  end

  defp asker!(subject \\ "dir-asker") do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address: "0x" <> String.duplicate("d", 40)
    })
  end

  defp paid_report!(tool, asker, amount_atomic, note, opts \\ []) do
    report =
      Forum.file_priority_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_failure,
          note: note,
          priority_amount_atomic: amount_atomic,
          payment_intent_id: Ash.UUID.generate()
        },
        actor: asker
      )

    if Keyword.get(opts, :credit, true) do
      # The credit is written by Patchbay's own escrow relay, which no policy
      # names; the fixture stands in for that relay, not for a caller.
      {:ok, credited} =
        Forum.record_escrow_credit(
          report,
          %{
            escrow_status: :credited,
            escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64),
            escrow_funded_at: DateTime.utc_now()
          },
          authorize?: false
        )

      credited
    else
      report
    end
  end

  defp card_chunk(html, slug) do
    card =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s|a.pb-dir-card[href="/sites/#{slug}"]|)
      |> LazyHTML.to_html()

    assert card != "", "no directory card linked to /sites/#{slug}"
    card
  end

  defp post_order(html, notes) do
    Enum.map(notes, fn note ->
      case :binary.match(html, note) do
        {at, _} -> at
        :nomatch -> flunk("post #{inspect(note)} is missing")
      end
    end)
  end

  describe "site directory catalog" do
    test "the homepage and /sites show the same grid of at least ten entries", %{conn: conn} do
      home = conn |> get(~p"/") |> html_response(200)
      html = conn |> get(~p"/sites") |> html_response(200)

      for page <- [home, html] do
        cards = page |> LazyHTML.from_document() |> LazyHTML.query("a.pb-dir-card")
        assert length(Enum.to_list(cards)) >= 10
      end

      for brand <- @required_brands do
        assert html =~ brand
      end

      assert html =~ ~s(href="/sites/render")
      assert html =~ ~s(href="/sites/netlify")
      assert html =~ ~s(href="/sites/openai")
      assert html =~ ~s(href="/sites/chrome")
      assert html =~ ~s(href="/sites/shopify")
    end

    test "a site card is one link to that site's page", %{conn: conn} do
      home = conn |> get(~p"/sites") |> html_response(200)
      card = card_chunk(home, "chrome")
      assert card =~ ~s(alt="Screenshot of google.com")
      assert card =~ "Browser support"
      assert card =~ "Source verified"
      assert length(String.split(card, "<a ")) == 2, "a card is one link with none inside it"

      site = conn |> get(~p"/sites/chrome") |> html_response(200)
      assert site =~ "Chrome"
      assert site =~ ~s(id="pb-site-tools")
      assert site =~ ~s(id="pb-site-posts")
    end
  end

  describe "site and tool pages" do
    test "the site page lists posts before tools", %{conn: conn} do
      html = conn |> get(~p"/sites/chrome") |> html_response(200)

      {tools_at, _} = :binary.match(html, ~s(id="pb-site-tools"))
      {posts_at, _} = :binary.match(html, ~s(id="pb-site-posts"))
      assert posts_at < tools_at
    end

    test "a tool row opens that tool's page", %{conn: conn} do
      Rooms.create_seeded_room!("dir-tool-row")

      site = conn |> get(~p"/sites/patchbay") |> html_response(200)
      assert site =~ ~s(href="/sites/patchbay/tools/uplift_current_skill_v1")

      tool =
        conn
        |> get(~p"/sites/patchbay/tools/uplift_current_skill_v1")
        |> html_response(200)

      assert tool =~ "uplift_current_skill_v1"
      assert tool =~ ~s(id="pb-tool-posts")
    end

    test "the tool page lists only that tool's posts, paid first", %{conn: conn} do
      site = site!("tools-only.example")
      checkout = tool!(site, %{name: "checkout"})
      search = tool!(site, %{name: "search", contract_sha256: @other_contract})
      paid_report!(checkout, asker!(), 5_000_000, "paid checkout post")
      report!(checkout, %{note: "checkout stayed empty"})
      report!(search, %{note: "search returned nothing"})

      tool =
        conn
        |> get(~p"/sites/tools-only.example/tools/checkout")
        |> html_response(200)

      assert tool =~ "checkout stayed empty"
      refute tool =~ "search returned nothing"
      [paid, unpaid] = post_order(tool, ["paid checkout post", "checkout stayed empty"])
      assert paid < unpaid
    end

    test "posts page at twenty with a cursor link", %{conn: conn} do
      site = site!("paged.example")
      tool = tool!(site)
      for n <- 1..21, do: report!(tool, %{note: "paged post number #{n}"})

      first = conn |> get(~p"/sites/paged-example") |> html_response(200)
      assert first =~ "paged post number 21"
      refute first =~ "paged post number 1<"

      assert [next] =
               Regex.run(
                 ~r|href="/sites/paged-example\?posts_after=([^#"]+)#pb-site-posts"|,
                 first,
                 capture: :all_but_first
               )

      second =
        conn
        |> get(~p"/sites/paged-example", posts_after: URI.decode_www_form(next))
        |> html_response(200)

      assert second =~ "paged post number 1<"
      refute second =~ "paged post number 21"
      refute second =~ "posts_after="

      expired = conn |> get(~p"/sites/paged-example", posts_after: "not-a-cursor")
      assert redirected_to(expired) == "/sites/paged-example#pb-site-posts"
    end

    test "the site page lists posts from every tool on the site", %{conn: conn} do
      site = site!("site-wide.example")
      checkout = tool!(site, %{name: "checkout"})
      search = tool!(site, %{name: "search", contract_sha256: @other_contract})
      report!(checkout, %{note: "checkout stayed empty"})
      report!(search, %{note: "search returned nothing"})

      html = conn |> get(~p"/sites/site-wide.example") |> html_response(200)

      assert html =~ "checkout stayed empty"
      assert html =~ "search returned nothing"
    end
  end

  describe "paid placement ranking" do
    setup do
      site = site!("rank.example")
      tool = tool!(site)
      asker = asker!()
      %{site: site, tool: tool, asker: asker}
    end

    test "25 USDC settled ranks above 5 USDC settled", %{
      conn: conn,
      site: site,
      tool: tool,
      asker: asker
    } do
      paid_report!(tool, asker, 5_000_000, "five usdc post")
      paid_report!(tool, asker, 25_000_000, "twenty five usdc post")

      html = conn |> get(~p"/sites/#{site.origin}") |> html_response(200)
      [twenty_five, five] = post_order(html, ["twenty five usdc post", "five usdc post"])
      assert twenty_five < five
      assert html =~ "Bounty · 25.00 USDC · funding details"
      assert html =~ "Bounty · 5.00 USDC · funding details"
    end

    test "5 USDC settled ranks above unpaid", %{
      conn: conn,
      site: site,
      tool: tool,
      asker: asker
    } do
      report!(tool, %{note: "unpaid later post"})
      paid_report!(tool, asker, 5_000_000, "five usdc post")

      html = conn |> get(~p"/sites/#{site.origin}") |> html_response(200)
      [paid, unpaid] = post_order(html, ["five usdc post", "unpaid later post"])
      assert paid < unpaid
    end

    test "pending 100 USDC does not promote a post", %{
      conn: conn,
      site: site,
      tool: tool,
      asker: asker
    } do
      paid_report!(tool, asker, 5_000_000, "five usdc settled")
      paid_report!(tool, asker, 100_000_000, "pending hundred usdc post", credit: false)

      html = conn |> get(~p"/sites/#{site.origin}") |> html_response(200)
      assert html =~ "Bounty · 5.00 USDC · funding details"
      assert html =~ "Bounty · 100.00 USDC · funding details"

      # The label names the bounty and links to its funding details whether or
      # not the money has arrived. Money that has not settled buys nothing: the
      # newer pending post sorts with the unpaid posts, below the settled one.
      [settled, pending] = post_order(html, ["five usdc settled", "pending hundred usdc post"])
      assert settled < pending
    end

    test "equal paid totals put the newest first", %{
      conn: conn,
      site: site,
      tool: tool,
      asker: asker
    } do
      paid_report!(tool, asker, 5_000_000, "older equal paid")
      paid_report!(tool, asker, 5_000_000, "newer equal paid")

      html = conn |> get(~p"/sites/#{site.origin}") |> html_response(200)
      [newer, older] = post_order(html, ["newer equal paid", "older equal paid"])
      assert newer < older
    end

    test "unpaid posts are newest first", %{conn: conn, site: site, tool: tool} do
      report!(tool, %{note: "older unpaid post"})
      report!(tool, %{note: "newer unpaid post"})

      html = conn |> get(~p"/sites/#{site.origin}") |> html_response(200)
      [newer, older] = post_order(html, ["newer unpaid post", "older unpaid post"])
      assert newer < older
    end
  end

  describe "support is not inventory" do
    test "an official supporter is not shown as exposing tools", %{conn: conn} do
      home = conn |> get(~p"/sites") |> html_response(200)
      netlify = card_chunk(home, "netlify")

      assert netlify =~ "Official supporter"
      refute netlify =~ "Exposes tools"
      refute netlify =~ ~r/\d+ tools?/

      site = conn |> get(~p"/sites/netlify") |> html_response(200)
      assert site =~ "Official supporter"
      assert site =~ "No public tool inventory"

      assert site =~
               "No public WebMCP tool inventory has been verified for this entry. Discussions about the company appear above."
    end

    test "published inventories come from the owner's own publication", %{conn: conn} do
      Catalog.sync!()

      shopify = conn |> get(~p"/sites/shopify") |> html_response(200)
      assert shopify =~ "Official tool inventory"
      assert shopify =~ ~s(href="/sites/shopify/tools/proceed_to_checkout")
      refute shopify =~ "start_checkout"

      tool = conn |> get(~p"/sites/shopify/tools/proceed_to_checkout") |> html_response(200)
      assert tool =~ ~s(href="https://shopify.dev/docs/api/web-mcp")

      patchbay = conn |> get(~p"/sites/patchbay") |> html_response(200)
      assert patchbay =~ "Official tool inventory"

      for name <- Capabilities.names() do
        assert patchbay =~ ~s(href="/sites/patchbay/tools/#{name}")
      end
    end

    test "a missing screenshot or logo falls back in place", %{conn: conn} do
      site!("bare-plate.example")

      html = conn |> get(~p"/sites") |> html_response(200)
      card = card_chunk(html, "bare-plate-example")

      assert card =~ "pb-dir-shot-empty"
      assert card =~ "pb-dir-logo-mark"
      refute card =~ ~s(<img)
      refute card =~ ~s(class="pb-dir-logo")
    end
  end

  describe "preserved routes" do
    test "old report and origin addresses still open the same records", %{conn: conn} do
      report =
        "alias.example"
        |> site!()
        |> tool!()
        |> report!(%{note: "the alias still works"})

      posts = conn |> get(~p"/posts/#{report.id}") |> html_response(200)
      reports = conn |> get(~p"/reports/#{report.id}") |> html_response(200)

      assert posts =~ "the alias still works"
      assert reports =~ "the alias still works"

      origin = conn |> get(~p"/sites/google.com") |> html_response(200)
      slug = conn |> get(~p"/sites/chrome") |> html_response(200)

      assert origin =~ "Chrome"
      assert slug =~ "Chrome"
    end
  end
end
