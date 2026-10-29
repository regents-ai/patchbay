defmodule PatchbayWeb.OpenEditionTest do
  @moduledoc """
  The open address (`PatchbayWeb.SiteEdition`) shows nothing about money,
  crypto or wallets: its main pages, read as a visitor and as a signed-in
  person, carry none of the words for them, in their text, in what a
  screen reader announces or in their Markdown. The same pages at patchbay.help keep them.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile

  @contract String.duplicate("a", 64)
  @arguments String.duplicate("c", 64)

  @money ~r/\bUSDC\b|\bcredits?\b|\boffers?\b|\bpoints?\b|\bx402\b|\bwallets?\b|\btips?\b|\btipped\b|\bbount(y|ies)\b|\bpriority\b|\bescrow\w*|\bpaid\b|\bpays?\b|\bpayments?\b|\bfund(s|ing)?\b|\bUSD\b|\bonchain\b/i

  # The token and ENS names, by their own capitals: Regents, the company, is
  # not money.
  @token ~r/\$REGENT|\bREGENT\b|\bENS\b/

  setup do
    site = Forum.register_site!("shop.example.com")

    tool =
      Forum.observe_tool!(%{
        site_id: site.id,
        address: "https://#{site.origin}/",
        name: "checkout",
        contract_sha256: @contract
      })

    asker =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:open-asker",
        wallet_address: "0x" <> String.duplicate("a", 40)
      })

    report =
      Forum.file_priority_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: @arguments,
          verdict: :verified_failure,
          note: "The cart never changed.",
          priority_amount_atomic: 5_000_000,
          payment_intent_id: Ash.UUID.generate()
        },
        actor: asker
      )

    answerer =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:open-answerer",
        wallet_address: "0x" <> String.duplicate("b", 40)
      })

    Forum.add_reply!(
      %{
        report_id: report.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :verified_success,
        note: "Emptying the cart first made it change."
      },
      actor: answerer
    )

    %{site: site, report: report, asker: asker}
  end

  test "the open address's pages say nothing about money", %{
    conn: conn,
    site: site,
    report: report,
    asker: asker
  } do
    conn = on_open(conn)

    # The paid report and its reply are there, only without their money.
    thread = conn |> get(PostAddress.path(report)) |> html_response(200)
    assert thread =~ "The cart never changed."
    assert thread =~ "Emptying the cart first made it change."

    assert money_on(pages(site, report, asker), &(conn |> get(&1) |> html_response(200))) == %{}
  end

  test "the open address's pages as Markdown say nothing about money", %{
    conn: conn,
    site: site,
    report: report,
    asker: asker
  } do
    conn = conn |> on_open() |> put_req_header("accept", "text/markdown")

    assert money_on(pages(site, report, asker), &(conn |> get(&1) |> response(200))) == %{}
  end

  test "signed in, the open address's pages and account say nothing about money", %{
    conn: conn,
    site: site,
    report: report,
    asker: asker
  } do
    conn = conn |> on_open() |> signed_in(asker)

    assert money_on(pages(site, report, asker), &(conn |> get(&1) |> html_response(200))) == %{}

    # Each account page as first drawn, and once connected.
    assert money_on(~w(/account /account/inbox /account/profile), fn path ->
             {:ok, view, html} = live(conn, path)
             html <> render(view)
           end) == %{}
  end

  test "the same pages at patchbay.help keep the paid report", %{conn: conn, report: report} do
    html = conn |> get(PostAddress.path(report)) |> html_response(200)

    assert html =~ "5.00 USDC on this report"
    assert html =~ "Buy $REGENT"

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(PostAddress.path(report))
      |> response(200)

    assert markdown =~ "- Bounty: "
  end

  test "patchbay.help's About keeps its Payments section", %{conn: conn} do
    assert conn |> get("/about") |> html_response(200) =~ "Token contract"
    refute conn |> on_open() |> get("/about") |> html_response(200) =~ "Token contract"
  end

  defp pages(site, report, asker),
    do: [
      "/",
      PostAddress.path(report),
      "/?q=cart",
      "/sites",
      "/#{site.origin}",
      "/#{site.origin}/tools/checkout",
      AgentProfile.profile_url(asker),
      "/help",
      "/about"
    ]

  # Each page that names money, with the words it uses.
  defp money_on(paths, read) do
    for path <- paths, words = money_words(read.(path)), words != [], into: %{}, do: {path, words}
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end

  # The page's words and what assistive technology reads out, never its
  # markup, scripts or class names. Markdown is all words.
  defp money_words("#" <> _markdown = text), do: words_for_money([text])

  defp money_words(html) do
    document =
      html
      |> String.replace(~r{<(script|style|template)\b.*?</\1>}s, "")
      |> LazyHTML.from_document()

    body = LazyHTML.query(document, "body")

    announced =
      for attribute <- ~w(aria-label title alt placeholder),
          value <- LazyHTML.attribute(LazyHTML.query(body, "[#{attribute}]"), attribute),
          do: value

    words_for_money(
      [LazyHTML.text(body) | announced] ++ [LazyHTML.text(LazyHTML.query(document, "title"))]
    )
  end

  defp words_for_money(words) do
    words
    |> Enum.flat_map(&(Regex.scan(@money, &1) ++ Regex.scan(@token, &1)))
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end
end
