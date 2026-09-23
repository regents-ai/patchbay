defmodule PatchbayWeb.Forum.DirectoryTest do
  @moduledoc """
  The WebMCP directory slice: catalog grid, site → tool → post, and bounty
  ranking from funded, unanswered escrow only.
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

  # No page read writes the catalog any more; the directory is imported once,
  # the way boot does it.
  setup do
    Catalog.sync!()
    :ok
  end

  defp site!(origin), do: Forum.register_site!(origin)

  # A site page's whole tool inventory, read the way a reader would: page by
  # page, following each "More tools" link.
  defp inventory(conn, path) do
    html = conn |> get(path) |> html_response(200)

    case Regex.run(~r{href="([^"]*\?tools_after=[^"#]*)#pb-site-tools"}, html) do
      [_, next] -> html <> inventory(conn, next)
      nil -> html
    end
  end

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

  defp question!(site, tool_name, title) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        subject_tool_name: tool_name,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        body_markdown: "Asked on the board."
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )
  end

  # A distinct, well-formed contract digest for the n-th version of a tool.
  defp version_digest(n),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp catalog_tool!(slug, name) do
    site = Forum.get_site_by_slug!(slug)
    Enum.find(Forum.list_tools_for_site!(site.id).results, &(&1.name == name))
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
          payment_intent_id: Ash.UUID.generate(),
          bounty_paid_with: :usdc
        },
        actor: asker
      )

    if Keyword.get(opts, :credit, true) do
      # The credit is written by Patchbay's own escrow relay, which no policy
      # names; the fixture stands in for that relay, not for a caller.
      {:ok, submitted} =
        Forum.record_escrow_credit(
          report,
          %{
            escrow_status: :credit_submitted,
            escrow_credit_tx_hash: "0x" <> String.duplicate("1", 64)
          },
          authorize?: false
        )

      {:ok, credited} =
        Forum.confirm_escrow_credit(
          submitted,
          %{escrow_funded_at: DateTime.utc_now()},
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
    test "the site page opens with the entry's facts, then its tools, then its posts",
         %{conn: conn} do
      html = conn |> get(~p"/sites/chrome") |> html_response(200)

      {about_at, _} = :binary.match(html, ~s(id="pb-site-about"))
      {tools_at, _} = :binary.match(html, ~s(id="pb-site-tools"))
      {posts_at, _} = :binary.match(html, ~s(id="pb-site-posts"))
      assert about_at < tools_at and tools_at < posts_at
      refute html =~ "About this site and its tools"
    end

    test "a tool row opens that tool's page", %{conn: conn} do
      Rooms.create_seeded_room!("dir-tool-row")

      site = inventory(conn, ~p"/sites/patchbay")
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

    test "the tool page lists questions that only name the tool", %{conn: conn} do
      site = site!("named-tool.example")
      tool!(site, %{name: "checkout"})
      question!(site, "checkout", "Why does checkout drop the coupon?")
      question!(site, "search", "Why does search ignore quotes?")

      tool = conn |> get(~p"/sites/named-tool.example/tools/checkout") |> html_response(200)

      assert tool =~ "Why does checkout drop the coupon?"
      refute tool =~ "Why does search ignore quotes?"
    end

    test "the tool page lists posts about versions past the first page of its history",
         %{conn: conn} do
      site = site!("many-versions.example")

      [oldest | _newer] =
        for n <- 1..26 do
          tool!(site, %{contract_sha256: version_digest(n)})
        end

      report!(oldest, %{note: "filed against the very first version"})

      first = conn |> get(~p"/sites/many-versions.example/tools/checkout") |> html_response(200)

      # The history shows 25 versions a page; the post's version is on the
      # second page, and the post is still on the first page of posts.
      assert first =~ "filed against the very first version"
      assert first =~ "after="
    end

    test "a site's post count includes questions that name no tool", %{conn: conn} do
      site = site!("counted.example")
      question!(site, nil, "Does this site have any tools at all?")

      card = conn |> get(~p"/sites") |> html_response(200) |> card_chunk("counted-example")
      assert card =~ "1 agent post"
    end
  end

  describe "tool names" do
    test "a published name keeps its hyphens, dots and case", %{conn: conn} do
      site = site!("names.example")
      tool!(site, %{name: "grid-sort"})
      tool!(site, %{name: "Grid.Sort", contract_sha256: @other_contract})
      question!(site, "grid-sort", "grid-sort ignores the second column")

      page = conn |> get(~p"/sites/names.example/tools/grid-sort") |> html_response(200)
      assert page =~ "grid-sort ignores the second column"

      assert conn |> get(~p"/sites/names.example/tools/Grid.Sort") |> html_response(200) =~
               "Grid.Sort"

      search =
        conn
        |> get("/forum/search", %{"origin" => "names.example", "tool_name" => "grid-sort"})
        |> json_response(200)

      assert [%{"title" => "grid-sort ignores the second column"}] = search["results"]
    end
  end

  describe "bounty ranking" do
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

    test "a bounty whose answer was accepted no longer ranks first", %{
      conn: conn,
      site: site,
      tool: tool,
      asker: asker
    } do
      answered = paid_report!(tool, asker, 25_000_000, "answered twenty five usdc post")
      paid_report!(tool, asker, 5_000_000, "open five usdc post")
      report!(tool, %{note: "plain newest post"})

      answerer =
        Identity.upsert_from_privy!(%{
          privy_user_id: "did:privy:dir-answerer",
          wallet_address: "0x" <> String.duplicate("e", 40)
        })

      {:ok, reply} =
        Forum.add_reply(
          %{
            report_id: answered.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :verified_failure,
            note: "Retry with the other endpoint."
          },
          actor: answerer
        )

      {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)
      {:ok, _accepted} = Forum.accept_reply(answered, reply.id, actor: asker)

      html = conn |> get(~p"/sites/#{site.origin}") |> html_response(200)

      [open, plain, answered] =
        post_order(html, [
          "open five usdc post",
          "plain newest post",
          "answered twenty five usdc post"
        ])

      assert open < plain and plain < answered
    end
  end

  describe "support is not inventory" do
    test "a site an agent merely named is not shown as exposing tools", %{conn: conn} do
      site!("named-only.example")

      card = conn |> get(~p"/sites") |> html_response(200) |> card_chunk("named-only-example")
      assert card =~ "Mentioned by agents"
      refute card =~ "Exposes tools"
      refute card =~ ~r/\d+ tools?/

      page = conn |> get(~p"/sites/named-only.example") |> html_response(200)
      assert page =~ "Mentioned by agents"
      assert page =~ "Tool inventory unverified"
      refute page =~ "Observed tool inventory"
    end

    test "reimporting the catalog neither moves a documented tool's checked date nor invents its declaration",
         %{conn: conn} do
      first = catalog_tool!("shopify", "proceed_to_checkout")
      Catalog.sync!()
      again = catalog_tool!("shopify", "proceed_to_checkout")

      entry = Enum.find(Catalog.entries(), &(&1.slug == "shopify"))
      assert DateTime.compare(first.last_seen_at, entry.last_verified_at) == :eq
      assert again.last_seen_at == first.last_seen_at
      assert is_nil(again.raw_definition)

      site = conn |> get(~p"/sites/shopify") |> html_response(200)
      assert site =~ "Verified 11 Sep 2026"

      tool = conn |> get(~p"/sites/shopify/tools/proceed_to_checkout") |> html_response(200)
      refute tool =~ "Raw schemas and declaration"
    end

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
               "No public WebMCP tool inventory has been verified for this entry. Discussions about the company appear below."
    end

    test "published inventories come from the owner's own publication", %{conn: conn} do
      shopify = conn |> get(~p"/sites/shopify") |> html_response(200)
      assert shopify =~ "Official tool inventory"
      assert shopify =~ ~s(href="/sites/shopify/tools/proceed_to_checkout")
      refute shopify =~ "start_checkout"

      tool = conn |> get(~p"/sites/shopify/tools/proceed_to_checkout") |> html_response(200)
      assert tool =~ ~s(href="https://shopify.dev/docs/api/web-mcp")

      patchbay = inventory(conn, ~p"/sites/patchbay")
      assert patchbay =~ "Official tool inventory"

      for name <- Capabilities.names() do
        assert patchbay =~ ~s(href="/sites/patchbay/tools/#{name}")
      end
    end

    test "a missing screenshot shows the domain on a plain plate", %{conn: conn} do
      site!("bare-plate.example")

      html = conn |> get(~p"/sites") |> html_response(200)
      card = card_chunk(html, "bare-plate-example")

      assert card =~ "pb-dir-shot-empty"
      refute card =~ ~s(class="pb-dir-shot")
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
