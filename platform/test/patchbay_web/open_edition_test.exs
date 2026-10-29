defmodule PatchbayWeb.OpenEditionTest do
  @moduledoc """
  The open address (`PatchbayWeb.SiteEdition`) shows nothing about money,
  crypto or wallets: its pages, read as a visitor and as a signed-in person,
  carry none of the words for them, in their text, in what a screen reader
  announces, in their title and share text or in their Markdown, and the
  pages about them are not there. What people post stays as they wrote it.
  The same pages at patchbay.help keep them.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias PatchbayTest.SharedBench

  @contract String.duplicate("a", 64)
  @arguments String.duplicate("c", 64)

  @money ~r/\bUSDC\b|\bcredits?\b|\boffers?\b|\bpoints?\b|\bx402\b|\bwallets?\b|\btips?\b|\btipped\b|\bbount(y|ies)\b|\bpriority\b|\bescrow\w*|\bpaid\b|\bpays?\b|\bpayments?\b|\bfund(s|ing)?\b|\bUSD\b|\bonchain\b/i

  # The token and ENS names, by their own capitals: Regents, the company, is
  # not money.
  @token ~r/\$REGENT|\bREGENT\b|\bENS\b/

  @crypto ~r/\bcrypto\w*|\bblockchains?\b|\bEthereum\b|\bon-?chain\b|\bSIWA\b|\bstak(e|es|ed|ing)\b|\bNFTs?\b/i

  # Ether, the Safe wallet and the Base chain by their own capitals, so the
  # common words "safe" and "base" are not them.
  @chain ~r/\bETH\b|\bSafe\b|\bBase\b/

  # A person's own post about a payment: what people write stays on the open
  # address as they wrote it.
  @own_words "My USDC never reached the wallet."
  @own_slug "my-usdc-never-reached-the-wallet"

  # The directory's sites and their tools are other sites' own names, from the
  # registry it was imported from. Only the directory page shows them, so only
  # there is a word inside one of them set aside.
  @directory "priv/data/site_directory.json"
             |> File.read!()
             |> Jason.decode!()
             |> Map.fetch!("sites")
             |> Enum.flat_map(&[&1["name"] | Enum.map(&1["tools"], fn t -> t["name"] end)])
             |> Enum.uniq()
             |> Enum.join("\n")

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

    own_post =
      Forum.file_report!(
        %{
          tool_id: tool.id,
          browser_session_id: Ash.UUID.generate(),
          arguments_sha256: String.duplicate("e", 64),
          verdict: :verified_failure,
          note: @own_words
        },
        actor: answerer
      )

    %{site: site, report: report, asker: asker, own_post: own_post}
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

  test "a person's own words about money stay on the open address", %{
    conn: conn,
    own_post: own_post
  } do
    conn = on_open(conn)

    assert conn |> get(PostAddress.path(own_post)) |> html_response(200) =~ @own_words
    assert conn |> get("/") |> html_response(200) =~ @own_words

    assert conn
           |> put_req_header("accept", "text/markdown")
           |> get(PostAddress.path(own_post))
           |> response(200) =~ @own_words
  end

  test "the Wallet Bench and the posts about wallets are patchbay.help's", %{conn: conn} do
    SharedBench.share!()

    for path <- ~w(/wallet-bench /wallet-bench/how-it-works /api/wallet-bench /api/v1/docs) do
      assert conn |> get(path) |> response(200), path
      assert_error_sent 404, fn -> conn |> on_open() |> get(path) end
    end

    assert conn |> get("/blog/agent-wallet-bench-v7") |> html_response(200)
    assert conn |> on_open() |> get("/blog/agent-wallet-bench-v7") |> html_response(404)

    assert conn |> get("/blog") |> html_response(200) =~ "/blog/agent-wallet-bench-v7"

    refute conn |> on_open() |> get("/blog") |> html_response(200) =~
             "/blog/agent-wallet-bench-v7"

    assert conn |> get("/sitemap.xml") |> response(200) =~ "/wallet-bench"
    open_sitemap = conn |> on_open() |> get("/sitemap.xml") |> response(200)
    refute open_sitemap =~ "/wallet-bench"
    refute open_sitemap =~ "/blog/agent-wallet-bench-v7"
  end

  test "the open address's guides and help for agents say nothing about money", %{conn: conn} do
    conn = on_open(conn)

    assert money_on(~w(/llms.txt /forum/help), &(conn |> get(&1) |> response(200))) == %{}
  end

  test "the ChatGPT app says nothing about money, with identities off and on", %{conn: conn} do
    assert money_on(chatgpt_reads(), &chatgpt(conn, &1)) == %{}

    config = Application.fetch_env!(:regent_mcp_agents, :config)
    on_exit(fn -> Application.put_env(:regent_mcp_agents, :config, config) end)

    Application.put_env(:regent_mcp_agents, :config,
      enabled?: true,
      audience: "patchbay",
      hosted_signer: [base_url: "http://127.0.0.1:1", key: String.duplicate("k", 32)]
    )

    assert money_on(chatgpt_reads(), &chatgpt(conn, &1)) == %{}
  end

  # A page's tools come from the manifest, less the ones its address leaves out.
  test "the page tools the open address offers say nothing about money" do
    assert for(
             tool <- Patchbay.Forum.Capabilities.site(),
             PatchbayWeb.SiteEdition.offers?(:open, tool),
             words =
               words_for_money([
                 Jason.encode!(Map.take(tool, [:title, :description, :input_schema]))
               ]),
             words != [],
             into: %{},
             do: {tool.name, words}
           ) == %{}
  end

  # The plugin's review cases and notes name the paid actions it refuses, as
  # the review asks them to; none of it names crypto.
  test "the ChatGPT plugin's own files say nothing about crypto" do
    plugin = Path.expand("../../../plugins/patchbay", __DIR__)
    files = Path.wildcard(Path.join(plugin, "**/*.{md,json}"))

    assert files != []

    assert for(
             file <- files,
             words = words_for([File.read!(file)], [@crypto, @chain]),
             words != [],
             into: %{},
             do: {file, words}
           ) == %{}
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

  test "the directory's finance category is Finance at the open address", %{conn: conn} do
    assert conn |> get("/sites") |> html_response(200) =~ "Finance &amp; Crypto"

    open = conn |> on_open() |> get("/sites") |> html_response(200)
    assert open =~ ~r{>\s*Finance\s*</option>}
    refute open =~ ~r{>\s*Finance &amp; Crypto\s*<}
  end

  test "the asker of a paid report accepts an answer only at patchbay.help", %{
    conn: conn,
    report: report,
    asker: asker
  } do
    accept = ~s(action="/posts/#{report.id}/accept")

    assert conn |> signed_in(asker) |> get(PostAddress.path(report)) |> html_response(200) =~
             accept

    refute conn
           |> on_open()
           |> signed_in(asker)
           |> get(PostAddress.path(report))
           |> html_response(200) =~
             accept
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
      "/about",
      "/contact",
      "/privacy",
      "/blog",
      "/incidents"
    ]

  # What the app reads from the ChatGPT address: its instructions, its tool list
  # and its help.
  defp chatgpt_reads,
    do: [
      {"initialize", %{}},
      {"tools/list", %{}},
      {"tools/call", %{"name" => "get_patchbay_help", "arguments" => %{}}}
    ]

  defp chatgpt(conn, {method, params}) do
    conn
    |> on_open()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/chatgpt/mcp",
      Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    )
    |> response(200)
  end

  # Each page that names money, with the words it uses.
  defp money_on(paths, read) do
    for path <- paths,
        words = path |> read.() |> money_words() |> without_directory(path),
        words != [],
        into: %{},
        do: {path, words}
  end

  defp without_directory(words, "/sites"),
    do: Enum.reject(words, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/i, @directory))

  defp without_directory(words, _path), do: words

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end

  # The page's words, what assistive technology reads out and the title and
  # description it is shared with, never its markup, scripts or class names.
  # Markdown, JSON and plain text are all words. A person's own post is left out.
  defp money_words(page), do: page |> String.replace([@own_words, @own_slug], "") |> page_words()

  defp page_words("<" <> _ = html), do: html_words(html)
  defp page_words(text), do: words_for_money([text])

  defp html_words(html) do
    document =
      html
      |> String.replace(~r{<(script|style|template)\b.*?</\1>}s, "")
      |> LazyHTML.from_document()

    body = LazyHTML.query(document, "body")

    announced =
      for attribute <- ~w(aria-label title alt placeholder),
          value <- LazyHTML.attribute(LazyHTML.query(body, "[#{attribute}]"), attribute),
          do: value

    shared =
      LazyHTML.attribute(
        LazyHTML.query(
          document,
          ~s(meta[name="description"], meta[property^="og:"], meta[name^="twitter:"])
        ),
        "content"
      )

    words_for_money(
      [LazyHTML.text(body) | announced] ++
        [LazyHTML.text(LazyHTML.query(document, "title")) | shared]
    )
  end

  defp words_for_money(words), do: words_for(words, [@money, @token, @crypto, @chain])

  defp words_for(words, patterns) do
    text = Enum.join(words, "\n")

    patterns
    |> Enum.flat_map(&Regex.scan(&1, text))
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end
end
