defmodule PatchbayWeb.Forum.DirectoryTest do
  @moduledoc """
  The WebMCP directory slice: catalog grid, site → tool → post, and paid
  placement ranking from settled escrow only.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
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
    href = ~s(href="/sites/#{slug}")

    case :binary.split(html, href) do
      [_before, rest] ->
        case :binary.split(rest, ~s(class="pb-dir-card")) do
          [card, _after] -> href <> card
          [card] -> href <> card
        end

      _missing ->
        flunk("no directory card linked to /sites/#{slug}")
    end
  end

  defp post_order(html, notes) do
    Enum.map(notes, fn note ->
      case :binary.match(html, note) do
        {at, _} -> at
        :nomatch -> flunk("post #{inspect(note)} is missing")
      end
    end)
  end

  describe "homepage catalog" do
    test "lists at least ten researched entries including the five required brands", %{
      conn: conn
    } do
      html = conn |> get(~p"/") |> html_response(200)

      cards = html |> String.split(~s(class="pb-dir-card")) |> length()
      assert cards - 1 >= 10

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
      home = conn |> get(~p"/") |> html_response(200)
      assert home =~ ~s(href="/sites/chrome")

      site = conn |> get(~p"/sites/chrome") |> html_response(200)
      assert site =~ "Chrome"
      assert site =~ ~s(id="pb-site-tools")
      assert site =~ ~s(id="pb-site-posts")
    end
  end

  describe "site and tool pages" do
    test "the site page lists tools before posts", %{conn: conn} do
      html = conn |> get(~p"/sites/chrome") |> html_response(200)

      {tools_at, _} = :binary.match(html, ~s(id="pb-site-tools"))
      {posts_at, _} = :binary.match(html, ~s(id="pb-site-posts"))
      assert tools_at < posts_at
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

    test "the tool page lists only that tool's posts", %{conn: conn} do
      site = site!("tools-only.example")
      checkout = tool!(site, %{name: "checkout"})
      search = tool!(site, %{name: "search", contract_sha256: @other_contract})
      report!(checkout, %{note: "checkout stayed empty"})
      report!(search, %{note: "search returned nothing"})

      tool =
        conn
        |> get(~p"/sites/tools-only.example/tools/checkout")
        |> html_response(200)

      assert tool =~ "checkout stayed empty"
      refute tool =~ "search returned nothing"
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
      assert html =~ "Paid placement · 25.00 USDC"
      assert html =~ "Paid placement · 5.00 USDC"
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
      refute html =~ "Paid placement · 100.00 USDC"
      assert html =~ "Paid placement · 5.00 USDC"
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
      home = conn |> get(~p"/") |> html_response(200)
      shopify = card_chunk(home, "shopify")

      assert shopify =~ "Official supporter"
      assert shopify =~ "No public tool inventory"
      refute shopify =~ "Exposes tools"
      refute shopify =~ "1 tool"
      refute shopify =~ "2 tools"

      site = conn |> get(~p"/sites/shopify") |> html_response(200)
      assert site =~ "Official supporter"
      assert site =~ "No public tool inventory"

      assert site =~
               "No public WebMCP tool inventory has been verified for this entry. Agent reports about the company can still appear below."
    end

    test "a missing screenshot or logo falls back in place", %{conn: conn} do
      site!("bare-plate.example")

      html = conn |> get(~p"/") |> html_response(200)
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
