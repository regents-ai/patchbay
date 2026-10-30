defmodule PatchbayWeb.OpenEditionTest do
  @moduledoc """
  The open address (`PatchbayWeb.SiteEdition`) shows nothing about money,
  crypto or wallets: its pages, read as a visitor and as a signed-in person,
  carry none of the words for them, in their text, in what a screen reader
  announces, in their title and share text, in their Markdown or in the JSON
  agents read and post through, and the pages about them are not there. What people post stays as they wrote it.
  The same pages at patchbay.help keep them.
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.OffersFixtures
  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Offers
  alias Patchbay.Payments.AgentTip
  alias PatchbayTest.SharedBench
  alias PatchbayWeb.SignedAgent
  alias PatchbayWeb.SiteEdition

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

  # A wallet address, whole or short.
  @address ~r/\b0x[0-9a-fA-F]{4,}/

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

    %{site: site, report: report, asker: asker, answerer: answerer, own_post: own_post}
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

  # capabilities.json and /forum/capabilities are the template's, which
  # Sentinel reads; they stay as they are.
  test "the open address's API description leaves out what only patchbay.help answers", %{
    conn: conn
  } do
    api = conn |> on_open() |> get("/openapi.json") |> json_response(200)

    for {path, item} <- api["paths"], {verb, _operation} <- item, verb in ~w(get post delete) do
      assert SiteEdition.answers?(:open, String.upcase(verb) <> " " <> path), path
    end

    assert api["paths"]["/forum/threads"]["post"]
    refute api["paths"]["/api/agent/payment_intents"]
    refute api["paths"]["/forum/offer-slots"]
    assert api["servers"] == [%{"url" => SiteEdition.url(:open)}]

    described = Jason.encode!(Map.drop(api, ["components"]))

    for name <- Map.keys(api["components"]["schemas"]) do
      assert Jason.encode!(api) =~ ~s("#/components/schemas/#{name}"), name
    end

    assert words_for_money([
             api["info"]["description"],
             api["externalDocs"]["description"] | Enum.map(api["tags"], & &1["description"])
           ]) == []

    assert described =~ "listSolvedFixes"
  end

  test "the open address's skill leaves out the tools only patchbay.help offers", %{conn: conn} do
    skill = conn |> on_open() |> get("/skill.md") |> response(200)
    index = conn |> on_open() |> get("/.well-known/skills/index.json") |> json_response(200)

    assert Enum.filter(SiteEdition.left_out_tools(:open), &(skill =~ "`#{&1}`")) == []
    assert skill =~ "## Core tools"
    assert skill =~ "## Tell your person"

    [description] = Regex.run(~r/^description: (".*")$/m, skill, capture: :all_but_first)
    description = Jason.decode!(description)
    assert [%{"name" => "patchbay", "description" => ^description}] = index["skills"]
    assert words_for_money([description]) == []

    # It names the agent sign-in standard and links its guide: that is how an
    # agent learns to sign.
    assert words_for_money([skill]) -- ["siwa", "SIWA"] == []
  end

  test "patchbay.help serves the API description and the skill as the repository has them", %{
    conn: conn
  } do
    assert conn |> get("/openapi.json") |> response(200) == File.read!("priv/public/openapi.json")

    assert build_conn() |> get("/skill.md") |> response(200) ==
             File.read!(Path.expand("../../../skills/patchbay/SKILL.md", __DIR__))

    [skill] =
      build_conn()
      |> get("/.well-known/skills/index.json")
      |> json_response(200)
      |> Map.fetch!("skills")

    assert skill["description"] =~ "USDC"
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
             SiteEdition.offers?(:open, tool),
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

  test "a person with no chosen name is a Member at the open address", %{
    conn: conn,
    asker: asker
  } do
    member = "Member " <> String.slice(String.replace(asker.id, "-", ""), 0, 8)
    open = conn |> on_open() |> get(AgentProfile.profile_url(asker)) |> html_response(200)
    assert open =~ member

    main = conn |> get(AgentProfile.profile_url(asker)) |> html_response(200)
    refute main =~ member
    assert main =~ "0xaaaa"

    # The menu under the person's picture names them the same way.
    assert conn |> on_open() |> signed_in(asker) |> get("/") |> html_response(200) =~ member
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

  test "each address serves its own terms, and patchbay.help's are the Regents Labs Terms of Use",
       %{conn: conn} do
    main = conn |> get("/terms") |> html_response(200)
    assert main =~ "DIGITAL ASSETS"
    refute main =~ "for open.patchbay.help"

    open = conn |> on_open() |> get("/terms") |> html_response(200)
    assert open =~ "https://patchbay.help/terms"
    refute open =~ "DIGITAL ASSETS"

    markdown =
      conn
      |> on_open()
      |> put_req_header("accept", "text/markdown")
      |> get("/terms")
      |> response(200)

    assert markdown == File.read!(Application.app_dir(:patchbay, "priv/legal/terms_open.md"))
  end

  describe "the reads and posts agents make as JSON" do
    # The site shows an Offer, and the asker has tipped the answerer.
    setup %{site: site, asker: asker, answerer: answerer} do
      market = Offers.open_site_market!(site.id, authorize?: false)
      place(market, 1, approved_version(advertiser(), "Site one", market))

      {:ok, intent} =
        RegentPayments.Purchase.prepare(
          AgentTip,
          %{amount_atomic: 1_000_000, recipient: answerer},
          asker
        )

      Patchbay.SettledPayment.settle!(intent, asker)
      :ok
    end

    test "a paid thread carries its money and Offers only at patchbay.help", %{
      conn: conn,
      report: report
    } do
      path = "/forum/threads/#{report.id}"

      assert ~w(agent_offers can_receive_usdc escrowed_usdc reward_eligibility) --
               money_keys(json_get(conn, path)) == []

      open = conn |> on_open() |> json_get(path)
      assert open =~ "The cart never changed."
      assert {money_keys(open), money_words(open)} == {[], []}
    end

    test "a search carries money and Offers only at patchbay.help", %{conn: conn, site: site} do
      path = "/forum/search?q=cart&origin=#{site.origin}"

      assert ~w(agent_offers can_receive_usdc escrowed_usdc) -- money_keys(json_get(conn, path)) ==
               []

      open = conn |> on_open() |> json_get(path)
      assert open =~ "The cart never changed."
      assert {money_keys(open), money_words(open)} == {[], []}
    end

    test "an agent's profile carries its wallet, bounties and tips only at patchbay.help", %{
      conn: conn,
      asker: asker
    } do
      path = "/api/agents/#{asker.public_id}"

      main = json_get(conn, path)
      assert main =~ asker.wallet_address

      assert ~w(bounties_posted tips_given tips_given_usdc tips_received_usdc wallet_address) --
               money_keys(main) == []

      open = conn |> on_open() |> json_get(path)
      assert Jason.decode!(open)["profile_id"] == asker.public_id
      assert {money_keys(open), money_words(open)} == {[], []}
    end

    test "a new post is followed by Offers only at patchbay.help", %{conn: conn, site: site} do
      SignedAgent.stub_siwa()
      agent = SignedAgent.pair!()

      main = conn |> ask(agent, site.origin) |> json_response(201)
      assert main["agent_offers"]["items"] |> Enum.map(& &1["text"]) == ["Site one"]
      assert [_delivery] = Ash.read!(Offers.Delivery, authorize?: false)

      open = conn |> on_open() |> ask(agent, site.origin) |> json_response(201)
      assert open["thread_id"]
      refute Map.has_key?(open, "agent_offers")
      assert [_delivery] = Ash.read!(Offers.Delivery, authorize?: false)
    end
  end

  defp json_get(conn, path),
    do: conn |> put_req_header("accept", "application/json") |> get(path) |> response(200)

  defp ask(conn, agent, origin) do
    conn
    |> SignedAgent.sign(agent)
    |> post(
      "/forum/threads",
      Jason.encode!(%{
        "site" => origin,
        "title" => "How do I change a booking here?",
        "body_markdown" => "The booking tool takes a date but I cannot find a way to move it.",
        "client_request_id" => Ecto.UUID.generate()
      })
    )
  end

  # The keys of a JSON answer that name money or Offers.
  defp money_keys(json) do
    ~r/"([a-z_]*(usdc|offers|reward|tip|wallet|bount)[a-z_]*)":/
    |> Regex.scan(json, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
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
      "/terms",
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

  defp words_for_money(words), do: words_for(words, [@money, @token, @crypto, @chain, @address])

  defp words_for(words, patterns) do
    text = Enum.join(words, "\n")

    patterns
    |> Enum.flat_map(&Regex.scan(&1, text))
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end
end
