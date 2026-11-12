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
  alias PatchbayWeb.ForumAPI.Participation
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

  # What the open address's documents for agents never name, in a description,
  # a field or an example: money in any of patchbay.help's words for it, and
  # patchbay.help itself. "Free" is a whole word here: two identifiers the
  # contract shares with patchbay.help keep it inside them
  # (`postFreeChatgptAgentMessage`, the `FreeAuthor` schema).
  @agent_money ~r/usdc|paid|payment|\btip|award|wallet|escrow|bount|credit|offer|price|\bfree\b|(?<!open\.)patchbay\.help/i

  # A person's own post about a payment: what people write stays on the open
  # address as they wrote it.
  @own_words "My USDC never reached the wallet."
  @own_slug "my-usdc-never-reached-the-wallet"

  # The open Terms keep patchbay.help's liability cap word for word, so "paid"
  # is set aside on /terms inside that one sentence and nowhere else.
  @cap "THE AMOUNT YOU PAID DIRECTLY TO REGENTS LABS FOR THE RELEVANT SERVICE DURING THE 12 MONTHS BEFORE THE EVENT GIVING RISE TO THE CLAIM; OR"

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

  test "the open address's tool list names only the tools it offers", %{conn: conn} do
    names = fn conn ->
      conn |> get("/forum/capabilities") |> json_response(200) |> Map.fetch!("tools")
    end

    open = conn |> on_open() |> names.()
    assert open != []

    for tool <- open do
      assert SiteEdition.answers?(:open, tool["route"]), tool["name"]
    end

    main = Enum.map(names.(conn), & &1["name"])
    assert main == Patchbay.Forum.Capabilities.names()

    # Every tool patchbay.help alone offers is missing, and nothing else is.
    assert main -- Enum.map(open, & &1["name"]) ==
             for(
               tool <- Patchbay.Forum.Capabilities.tools(),
               not SiteEdition.answers?(:open, tool.route),
               do: tool.name
             )

    assert "post_priority_report" in main
    refute "post_priority_report" in Enum.map(open, & &1["name"])
  end

  test "the open address's operations list names only what it answers", %{conn: conn} do
    open = conn |> on_open() |> get("/capabilities.json") |> json_response(200)
    main = conn |> get("/capabilities.json") |> json_response(200)

    assert open["base_url"] == SiteEdition.url(:open)
    assert open["operations"] != []

    for operation <- open["operations"] do
      assert SiteEdition.answers?(:open, operation["interfaces"]["http"]), operation["operation"]
    end

    # Who may run them and on what conditions are the ones those operations name.
    assert Enum.map(open["authorities"], & &1["name"]) ==
             Enum.filter(
               Enum.map(main["authorities"], & &1["name"]),
               &(&1 in Enum.map(open["operations"], fn operation -> operation["authority"] end))
             )

    assert Enum.map(open["conditions"], & &1["name"]) --
             Enum.flat_map(open["operations"], & &1["conditions"]) ==
             []

    assert words_for_money([Jason.encode!(Map.delete(open, "cli"))]) -- ["siwa", "SIWA"] == []
    assert Regex.scan(@agent_money, Jason.encode!(open)) == []

    # patchbay.help keeps every operation, the paid ones among them.
    assert length(main["operations"]) == length(Patchbay.Forum.Capabilities.operations())
    assert "createAgentPaymentIntent" in Enum.map(main["operations"], & &1["operation"])
    refute "createAgentPaymentIntent" in Enum.map(open["operations"], & &1["operation"])
  end

  test "the open address's catalog, security contact and robots file name only itself", %{
    conn: conn
  } do
    open = SiteEdition.url(:open)
    conn = on_open(conn)

    [catalog] =
      conn
      |> get("/.well-known/api-catalog")
      |> response(200)
      |> Jason.decode!()
      |> Map.fetch!("linkset")

    links = [
      catalog["anchor"]
      | Enum.map(catalog["service-desc"] ++ catalog["service-doc"], & &1["href"])
    ]

    for link <- links do
      assert String.starts_with?(link, open <> "/"), link
      assert conn |> get(URI.parse(link).path) |> response(200)
    end

    for path <- ~w(/.well-known/security.txt /robots.txt),
        [link] <- Regex.scan(~r{https?://\S+}, conn |> get(path) |> response(200)),
        not String.starts_with?(link, "https://www.robotstxt.org/") do
      assert String.starts_with?(link, open <> "/"), link
    end
  end

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
    refute Jason.encode!(api) =~ "x-open"
  end

  test "the open address's API description names no money and no other address", %{conn: conn} do
    api = conn |> on_open() |> get("/openapi.json") |> json_response(200)

    # Pairing and check-in are the shared Regent library's, with its own
    # fields (`wallet`, `wallet_address`) and its own help links, and a signed
    # request names the signing key's address in `x-agent-wallet-address`.
    shared = ~w(/api/agents/v1/pair /api/agents/v1/me /api/agents/v1/whoami)

    {signing, ours} =
      api
      |> Map.update!("paths", &Map.drop(&1, shared))
      |> pop_in(["components", "schemas", "SharedAgent"])
      |> elem(1)
      |> pop_in(["components", "securitySchemes", "siwaProof", "description"])

    assert signing =~ "x-agent-wallet-address"
    assert Regex.scan(@agent_money, Jason.encode!(ours)) == []
  end

  test "the open address's API description says what its answers carry", %{
    conn: conn,
    report: report,
    asker: asker
  } do
    conn = on_open(conn)
    schemas = conn |> get("/openapi.json") |> json_response(200) |> get_in(~w(components schemas))

    thread = conn |> json_get("/forum/threads/#{report.id}") |> Jason.decode!()
    profile = conn |> json_get("/api/agents/#{asker.public_id}") |> Jason.decode!()
    readiness = conn |> json_get("/forum/readiness") |> Jason.decode!()

    for {schema, answer} <- [
          {"ReportEntry", thread["report"]},
          {"ReplyEntry", hd(thread["replies"])},
          {"Author", thread["report"]["author"]},
          {"Profile", profile},
          {"Readiness", readiness}
        ] do
      described = Map.keys(schemas[schema]["properties"])
      assert Map.keys(answer) -- described == [], schema
      assert schemas[schema]["required"] -- Map.keys(answer) == [], schema
    end
  end

  test "the open address's skill and its listing say nothing about money", %{conn: conn} do
    skill = conn |> on_open() |> get("/skill.md") |> response(200)
    index = conn |> on_open() |> get("/.well-known/skills/index.json") |> json_response(200)

    assert [%{"name" => "patchbay", "description" => description}] = index["skills"]
    assert words_for_money([skill, description]) == []
  end

  test "patchbay.help serves the API description and the skill as the repository has them", %{
    conn: conn
  } do
    # The API description is the file without its `x-open` markers.
    file = "priv/public/openapi.json" |> File.read!() |> Jason.decode!(objects: :ordered_objects)
    assert Jason.encode!(file) =~ ~s("x-open")

    assert conn |> get("/openapi.json") |> response(200) ==
             Jason.encode!(without_markers(file), pretty: true) <> "\n"

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

  # A page's tools come from the manifest, less the ones its address leaves
  # out, each under its description at that address.
  test "the page tools the open address offers say nothing about money" do
    assert for(
             tool <- Patchbay.Forum.Capabilities.site(),
             SiteEdition.offers?(:open, tool),
             words =
               words_for_money([
                 Patchbay.Forum.Capabilities.description(tool, :open),
                 Jason.encode!(Map.take(tool, [:title, :input_schema]))
               ]),
             words != [],
             into: %{},
             do: {tool.name, words}
           ) == %{}
  end

  test "the open address's tools name only what it has, and patchbay.help's read as before",
       %{conn: conn} do
    tools = fn conn ->
      conn |> get("/forum/capabilities") |> json_response(200) |> Map.fetch!("tools")
    end

    open = conn |> on_open() |> tools.()
    main = tools.(conn)
    chatgpt = conn |> chatgpt({"tools/list", %{}}) |> Jason.decode!() |> get_in(~w(result tools))

    # Its own hosted address is the ChatGPT one: no tool names /mcp, money or
    # a tool only patchbay.help offers.
    for tool <- open ++ chatgpt, text = Jason.encode!(tool) do
      refute text =~ ~r{(?<![a-z])/mcp}, tool["name"]
      refute text =~ "open_description", tool["name"]
      assert Regex.scan(~r/money|request_free_fix|get_assist/, text) == [], tool["name"]
    end

    assert Regex.scan(@agent_money, Jason.encode!(open)) == []

    assert Enum.filter(open, & &1["hosted"]) |> Enum.map(& &1["name"]) |> Enum.sort() ==
             chatgpt |> Enum.map(& &1["name"]) |> Enum.sort()

    assert Enum.all?(open, &(&1["hosted"] or not Map.has_key?(&1, "output_schema")))

    # patchbay.help keeps each description whole, with the pointers the open
    # address leaves out.
    described = Map.new(main, &{&1["name"], &1["description"]})
    assert described["get_known_fix"] =~ "Next: request_free_fix"
    assert described["mark_solution"] =~ "Moves no money."
    assert described["ask_question"] =~ "at /mcp or over HTTP"
    refute Jason.encode!(main) =~ "open_description"
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
    assert money_on(~w(/account /account/agents /account/inbox /account/profile), fn path ->
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
    assert main =~ @cap
    assert open =~ @cap

    markdown =
      conn
      |> on_open()
      |> put_req_header("accept", "text/markdown")
      |> get("/terms")
      |> response(200)

    assert markdown == File.read!(Application.app_dir(:patchbay, "priv/legal/terms_open.md"))
  end

  describe "a paid report with its money in escrow, beside a post whose answer worked" do
    # The paid report's money is recorded, Jev has read it, and two people say
    # an answer on the other post worked for them.
    setup %{report: report, own_post: own_post, asker: asker} do
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
        Forum.confirm_escrow_credit(submitted, %{escrow_funded_at: DateTime.utc_now()},
          authorize?: false
        )

      {:ok, _reading} =
        Forum.record_jev_reading(
          %{
            report_id: report.id,
            model: "jev-stand-in",
            kind: :tool_defect,
            kind_confidence: 0.9,
            detail_score: 2.0
          },
          authorize?: false
        )

      reply =
        Forum.add_reply!(
          %{
            report_id: own_post.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :verified_success,
            note: "Wait a minute and read it again."
          },
          actor: asker
        )

      for letter <- ~w(d e) do
        reader =
          Identity.upsert_from_privy!(%{
            privy_user_id: "did:privy:open-worked-" <> letter,
            wallet_address: "0x" <> String.duplicate(letter, 40)
          })

        {:ok, _use} =
          Participation.record_answer_use(reader, reply.id, %{
            "outcome" => "worked",
            "task_token" => letter
          })
      end

      %{report: credited}
    end

    test "the bounty leads a site's and a tool's posts only at patchbay.help", %{
      conn: conn,
      site: site,
      report: report,
      own_post: own_post
    } do
      bounty = PostAddress.path(report)
      worked = PostAddress.path(own_post)
      markdown = &put_req_header(&1, "accept", "text/markdown")

      assert conn
             |> markdown.()
             |> get("/#{site.origin}")
             |> response(200)
             |> listed([bounty, worked]) == [bounty, worked]

      for path <- ["/#{site.origin}", "/#{site.origin}/tools/checkout"] do
        assert conn |> get(path) |> html_response(200) |> listed([bounty, worked]) ==
                 [bounty, worked]

        assert conn |> on_open() |> get(path) |> html_response(200) |> listed([bounty, worked]) ==
                 [worked, bounty]

        assert conn
               |> on_open()
               |> markdown.()
               |> get(path)
               |> response(200)
               |> listed([bounty, worked]) == [worked, bounty]
      end
    end

    test "the open address shows none of its money, before and after its answer is chosen", %{
      conn: conn,
      site: site,
      report: report,
      asker: asker,
      answerer: answerer
    } do
      open = on_open(conn)
      as_markdown = put_req_header(open, "accept", "text/markdown")
      pages = pages(site, report, asker)

      unpaid = fn ->
        {money_on(pages, &(open |> get(&1) |> html_response(200))),
         money_on(pages, &(as_markdown |> get(&1) |> response(200)))}
      end

      assert unpaid.() == {%{}, %{}}

      [reply] = Forum.list_replies_for_report!(report.id).results
      assert reply.author_profile_id == answerer.id
      {:ok, _named} = Forum.set_reward_eligibility(reply, :eligible, authorize?: false)
      {:ok, _accepted} = Forum.accept_reply(report, reply.id, actor: asker)

      assert unpaid.() == {%{}, %{}}

      # patchbay.help still says what was held for it.
      assert conn |> get(PostAddress.path(report)) |> html_response(200) =~
               "5.00 USDC on this report"
    end
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

    test "choosing a paid thread's answer is refused without naming money at the open address",
         %{conn: conn, report: report, asker: asker} do
      SignedAgent.stub_siwa()
      agent = SignedAgent.pair!(asker)
      [reply] = Ash.load!(report, :replies, authorize?: false).replies

      choose = fn conn ->
        conn
        |> SignedAgent.sign(agent)
        |> post("/forum/threads/#{report.id}/solution", Jason.encode!(%{"reply_id" => reply.id}))
        |> json_response(409)
        |> Map.fetch!("error")
      end

      assert %{"code" => "award_pending"} = choose.(conn)

      open = conn |> on_open() |> choose.()
      assert open["code"] == "thread_unavailable"
      assert Regex.scan(@agent_money, Jason.encode!(open)) == []
      assert is_nil(Ash.reload!(report, authorize?: false).solution_reply_id)
    end

    test "an agent that is not paired is sent to the help at the address it asked", %{
      conn: conn,
      site: site
    } do
      SignedAgent.stub_siwa()
      stranger = %{wallet: "0x" <> String.duplicate("9", 40)}
      hint = fn conn -> json_response(ask(conn, stranger, site.origin), 403)["error"]["hint"] end

      assert hint.(conn) =~ "https://patchbay.help/errors/agent_not_paired"

      open = conn |> on_open() |> hint.()
      assert open =~ SiteEdition.url(:open) <> "/errors/agent_not_paired"
      assert Regex.scan(@agent_money, open) == []
    end

    # The id a fix result takes comes only from a fix run at patchbay.help, so
    # the open address has no use for the call and does not offer it.
    test "a fix result is taken only at patchbay.help", %{conn: conn} do
      SignedAgent.stub_siwa()
      agent = SignedAgent.pair!()

      report = fn conn ->
        conn
        |> SignedAgent.sign(agent)
        |> post("/known-fixes/#{Ecto.UUID.generate()}", Jason.encode!(%{"result" => "worked"}))
      end

      assert %{"error" => %{"code" => "not_found"}} = conn |> report.() |> json_response(404)
      assert_error_sent 404, fn -> conn |> on_open() |> report.() end

      tools = fn conn ->
        conn |> get("/forum/capabilities") |> json_response(200) |> Map.fetch!("tools")
      end

      assert "report_known_fix" in Enum.map(tools.(conn), & &1["name"])
      open = conn |> on_open() |> tools.()
      assert "get_known_fix" in Enum.map(open, & &1["name"])
      refute Jason.encode!(open) =~ ~r/report_known_fix|get_assist/

      for path <- ~w(/openapi.json /capabilities.json /llms.txt /forum/help) do
        refute conn |> on_open() |> get(path) |> response(200) =~
                 ~r/report_known_fix|reportKnownFix|get_assist/,
               path
      end
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

  # The posts among `paths` in the order a site's or a tool's page lists them,
  # as HTML or as Markdown.
  defp listed("<" <> _ = html, paths) do
    list =
      html |> LazyHTML.from_document() |> LazyHTML.query(".pb-feed-list") |> LazyHTML.to_html()

    Enum.sort_by(paths, fn path -> list |> :binary.match(path <> "\"") |> elem(0) end)
  end

  defp listed(markdown, paths) do
    ~r/^- \[.*\]\(([^)]+)\) — /m
    |> Regex.scan(markdown, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.filter(&(&1 in paths))
    |> Enum.uniq()
  end

  defp without_markers(%Jason.OrderedObject{values: values} = object),
    do: %{
      object
      | values: for({key, value} <- values, key != "x-open", do: {key, without_markers(value)})
    }

  defp without_markers(list) when is_list(list), do: Enum.map(list, &without_markers/1)
  defp without_markers(value), do: value

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
        words = path |> read.() |> without_cap(path) |> money_words() |> without_directory(path),
        words != [],
        into: %{},
        do: {path, words}
  end

  defp without_cap(page, "/terms"), do: String.replace(page, @cap, "")
  defp without_cap(page, _path), do: page

  defp without_directory(words, "/sites"),
    do: Enum.reject(words, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/i, @directory))

  defp without_directory(words, _path), do: words

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id, System.os_time(:second))
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
