defmodule Patchbay.Forum.PostSummaryTest do
  @moduledoc """
  A report's page leads with the error it is about, word for word: in its tab
  title, its search description and what it tells search engines it holds.
  Checked on eight real reports.
  """

  use PatchbayWeb.ConnCase, async: false
  use ExUnitProperties

  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PostSummary
  alias PatchbayWeb.ErrorReports

  # What a searcher pastes from each error, and where the post quotes the
  # error: in a code block, only in its title, or nowhere.
  @searched %{
    "draft_07_output_schema" => {"unsupported dialect", :quoted},
    "entra_aadsts9010010" => {"AADSTS9010010", :quoted},
    "keyfleet_git_401" => {"Git needs a password for this fleet's code", :quoted},
    "keyfleet_join" => {"not_signed_in: Sign in first", :quoted},
    "touch_id" => {"no_touch_id", :title},
    "webmcp_model_context" =>
      {"Cannot read properties of undefined (reading 'registerTool')", :quoted},
    "x402_header_overflow" => {"UND_ERR_HEADERS_OVERFLOW", :quoted},
    "x402_payment_signature" => {"PAYMENT-SIGNATURE", :none}
  }

  @site %{display_name: nil, origin: "errors.example"}

  defp shown(report, kind \\ :help_needed),
    do:
      Map.merge(report, %{
        id: Ash.UUID.generate(),
        thread_kind: kind,
        note: nil,
        tool_names: [],
        site: @site
      })

  defp written(body, title \\ "A question"),
    do: %{
      id: Ash.UUID.generate(),
      thread_kind: :help_needed,
      title: title,
      note: nil,
      tool_names: [],
      site: @site,
      body_markdown: body
    }

  defp words(text), do: text |> String.split() |> Enum.join(" ")

  test "every report's description starts with its error, word for word, then what to do" do
    assert length(ErrorReports.all()) == 8

    for report <- ErrorReports.all() do
      post = shown(report)
      {searched, kind} = Map.fetch!(@searched, report.name)
      description = PostSummary.description(post)

      assert String.length(description) <= 155, report.name
      assert description =~ searched, report.name

      case kind do
        :quoted ->
          error = PostSummary.error(post)
          assert words(report.body_markdown) =~ error, report.name
          assert String.starts_with?(description, error), report.name
          assert String.length(description) > String.length(error) or String.length(error) > 115

        :title ->
          assert PostSummary.error(post) == searched, report.name
          assert String.starts_with?(description, searched <> " — "), report.name

        :none ->
          assert PostSummary.error(post) == nil
          assert String.starts_with?(description, report.title), report.name
      end
    end
  end

  test "a fix with its own words follows the error" do
    description =
      "x402_header_overflow" |> ErrorReports.get!() |> shown() |> PostSummary.description()

    assert description =~ ~r/UND_ERR_HEADERS_OVERFLOW.* Fix: on Node, start with NODE_OPTIONS/
  end

  test "the tab title leads with the error, then the rest of the title, cut between words" do
    for report <- ErrorReports.all() do
      post = shown(report)
      title = PostSummary.title(post)
      lead = PostSummary.error(post) || report.title

      assert String.length(title) <= 70, report.name
      kept = String.trim_trailing(title, "…")
      assert String.starts_with?(lead, kept) or String.starts_with?(kept, lead), report.name
    end

    touch_id = "touch_id" |> ErrorReports.get!() |> shown()
    assert touch_id.title =~ ~r/\Aregents auth login on a Mac: "no_touch_id"/

    assert PostSummary.title(touch_id) ==
             "no_touch_id — regents auth login on a Mac: after 5 minutes…"

    entra = "entra_aadsts9010010" |> ErrorReports.get!() |> shown()
    assert PostSummary.title(entra) =~ ~r/\Ainvalid_target AADSTS9010010: The resource parameter/
  end

  describe "a code block that holds no error" do
    test "is passed over for the next block, then the title" do
      assert PostSummary.error(written("```\n{}\n```\n\nThe page stayed blank.")) == nil
      assert PostSummary.error(written("```\n$ ---\n```\n\nThe page stayed blank.")) == nil

      body = "```\n$ npm install foo\n```\n\nThen:\n\n```\nError: Cannot find module foo\n```\n"
      assert PostSummary.error(written(body)) == "Error: Cannot find module foo"

      prompt = "```\nsean@mac:~/app$ make\nmake: *** No rule to make target 'all'.\n```\n"
      assert PostSummary.error(written(prompt)) == "make: *** No rule to make target 'all'."

      quoted =
        written("```\n$ regents auth login\n```\n", ~s(Login stops with "no_touch_id" on a Mac))

      assert PostSummary.error(quoted) == "no_touch_id"
      assert PostSummary.title(quoted) == "no_touch_id — Login stops with on a Mac"
    end

    test "never leaves the description empty or opening with a dash" do
      for body <- ["```\n{}\n```", "```\n$ ---\n```", "```\n$ npm install foo\n```"] do
        description = body |> written() |> PostSummary.description()
        assert description == "A question", body
      end
    end

    property "a body passed over unread holds no code block an error could come from" do
      check all(
              chars <-
                list_of(member_of([" ", "\t", "`", "~", "\n", "a", "-", "*", "1."]),
                  max_length: 80
                )
            ) do
        body = Enum.join(chars)

        coded? =
          body
          |> MDEx.parse_document!()
          |> Map.fetch!(:nodes)
          |> Enum.any?(fn node ->
            match?(%MDEx.CodeBlock{}, node) and node.literal =~ ~r/[a1]/
          end)

        assert PostSummary.error(written(body)) == nil or coded?
        if coded?, do: assert(PostSummary.error(written(body)) =~ ~r/[a1]/)
      end
    end

    property "every description and tab title has words of its own, and every address is words" do
      line = string(:printable, max_length: 40)

      fence =
        gen(all(lines <- list_of(line, max_length: 3)),
          do: "```\n" <> Enum.join(lines, "\n") <> "\n```"
        )

      prose = gen(all(text <- line), do: text)

      prompt =
        gen(all(text <- line, mark <- member_of(["$ ", "% ", "> ", "# ", "PS C:\\> "])),
          do: "```\n" <> mark <> text <> "\n```"
        )

      check all(
              kind <- member_of(Patchbay.Forum.Types.ThreadKind.values()),
              title <- one_of([line, constant(nil), constant("   ")]),
              note <- one_of([line, constant(nil)]),
              tools <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 10), max_length: 2),
              parts <- list_of(one_of([fence, prose, prompt]), max_length: 4)
            ) do
        post = %{
          id: Ash.UUID.generate(),
          thread_kind: kind,
          title: title,
          note: note,
          tool_names: tools,
          site: @site,
          body_markdown: Enum.join(parts, "\n\n")
        }

        description = PostSummary.description(post)
        title = PostSummary.title(post)

        for text <- [description, title] do
          assert String.trim(text) != ""
          refute text =~ ~r/\A\s|\A—/u
        end

        assert String.length(description) <= 155
        assert String.length(title) <= 70
        assert PostAddress.path(post) =~ ~r|\A/posts/[0-9a-f-]{36}/[a-z0-9_]+(-[a-z0-9_]+)*\z|
      end
    end
  end

  test "a post with no body is described by its own words" do
    post = %{
      id: Ash.UUID.generate(),
      thread_kind: :help_needed,
      title: nil,
      body_markdown: nil,
      tool_names: [],
      note: "The cart stayed empty."
    }

    assert PostSummary.description(post) == "The cart stayed empty."
  end

  describe "which posts lead with an error" do
    # The kind each of the eight is posted as on patchbay.help (read 28 Oct
    # 2026), and how each is headed as posted: by the error its code prints,
    # from the words its title quotes, or by its own title.
    @live %{
      "draft_07_output_schema" => {:success_story, :title},
      "entra_aadsts9010010" => {:success_story, :title},
      "keyfleet_git_401" => {:success_story, "Git needs a password for this fleet's code. "},
      "keyfleet_join" =>
        {:success_story, "not_signed_in: Sign in first: regents auth login --site keyfleet. "},
      "touch_id" => {:success_story, :title},
      "webmcp_model_context" => {:success_story, :title},
      "x402_header_overflow" =>
        {:discussion,
         "fetch failed cause.code: UND_ERR_HEADERS_OVERFLOW (Headers Overflow Error) — "},
      "x402_payment_signature" => {:success_story, :title}
    }

    defp shopify do
      [title, body] =
        "../../support/live_posts/shopify_cart_tools.md"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> String.split("\n\n", parts: 2)

      %{title: title, body_markdown: String.trim(body)}
    end

    test "a success story whose title quotes nothing keeps its title, though its code holds words" do
      post = shown(shopify(), :success_story)
      title = post.title

      assert post.body_markdown =~ "const tools = await document.modelContext.getTools();"
      assert PostSummary.error(post) == nil
      assert PostSummary.headline(post) == title

      assert PostSummary.title(post) ==
               "Shopify storefront WebMCP: add_to_cart and update_cart_lines replace…"

      assert String.starts_with?(PostSummary.description(post), title)

      assert PostAddress.path(post) ==
               "/posts/#{post.id}/shopify-storefront-webmcp-add_to_cart-and-update_cart_lines-replace-update_cart"

      for text <- [PostSummary.title(post), PostSummary.description(post), PostAddress.path(post)] do
        refute text =~ ~r/const|getTools/i
      end
    end

    test "each of the eight, as it is posted, leads with the error its title quotes, or its title" do
      for report <- ErrorReports.all() do
        {kind, lead} = Map.fetch!(@live, report.name)
        post = shown(report, kind)
        headline = PostSummary.headline(post)

        case lead do
          :title ->
            assert headline == report.title, report.name
            assert PostSummary.error(post) == nil, report.name
            assert String.starts_with?(PostSummary.description(post), report.title)

          words ->
            assert String.starts_with?(headline, words), report.name
            assert words(report.body_markdown) =~ PostSummary.error(post), report.name
            assert String.starts_with?(PostSummary.description(post), PostSummary.error(post))
        end

        assert PostAddress.path(post) == "/posts/#{post.id}/#{PostAddress.slug(headline)}"
      end
    end

    test "any other kind leads with the error only when its title quotes words its code prints" do
      body = "```\nTypeError: fetch failed at checkout.\n```\n\nThe cart \"hangs\" for ever."

      for kind <- [:discussion, :feature_request, :success_story] do
        quoted = %{written(body, ~s(Checkout: "fetch failed")) | thread_kind: kind}
        ticked = %{written(body, "Checkout: `fetch failed`") | thread_kind: kind}
        assert PostSummary.headline(quoted) == "fetch failed at checkout. Checkout"
        assert PostSummary.headline(ticked) == "fetch failed at checkout. Checkout"

        # Not quoted; quoted but only in the prose; quoted inside a longer word.
        for title <- ["Checkout: fetch failed", ~s(Checkout "hangs"), ~s(Checkout "fetch fail")] do
          post = %{written(body, title) | thread_kind: kind}
          assert PostSummary.headline(post) == title, "#{kind} #{title}"
          assert PostSummary.error(post) == nil
        end
      end
    end

    test "a question or a report leads with its error whatever its title quotes" do
      report = ErrorReports.get!("entra_aadsts9010010")
      refute report.title =~ ~s(")

      for kind <- [:discussion, :feature_request, :success_story] do
        assert PostSummary.headline(shown(report, kind)) == report.title, "#{kind}"
      end

      for kind <- [:help_needed, :failure_report] do
        assert PostSummary.headline(shown(report, kind)) =~ ~r/\Ainvalid_target AADSTS9010010: /,
               "#{kind}"
      end
    end

    test "a solved question still leads with its error" do
      post = "keyfleet_join" |> ErrorReports.get!() |> shown()
      solved = Map.put(post, :solution_reply_id, Ash.UUID.generate())

      assert PostSummary.headline(solved) == PostSummary.headline(post)
      assert PostSummary.headline(solved) =~ ~r/\Anot_signed_in: /
    end
  end

  describe "a title that quotes the error a code block prints" do
    test "starts the error at the quoted words, not at the check's name before them" do
      report = ErrorReports.get!("keyfleet_join")
      assert report.title =~ ~s(regents keyfleet: "not_signed_in", then)
      assert report.body_markdown =~ "✗ sign-in  not_signed_in: Sign in first:"

      for kind <- [:help_needed, :failure_report, :success_story, :discussion] do
        post = shown(report, kind)

        assert PostSummary.error(post) ==
                 "not_signed_in: Sign in first: regents auth login --site keyfleet."

        assert PostSummary.headline(post) =~
                 ~r/\Anot_signed_in: Sign in first: regents auth login --site keyfleet\. regents keyfleet: then agent_not_paired or person_not_here\. /

        assert PostSummary.title(post) ==
                 "not_signed_in: Sign in first: regents auth login --site keyfleet…"

        assert PostSummary.description(post) =~
                 ~r/\Anot_signed_in: Sign in first: regents auth login --site keyfleet\. /

        assert PostAddress.path(post) ==
                 "/posts/#{post.id}/not_signed_in-sign-in-first-regents-auth-login-site-keyfleet-regents-keyfleet"
      end
    end

    test "keeps the whole sentence when the quoted words are only part of a longer word" do
      post =
        written("```\nError: signed_in_twice is not allowed.\n```\n", ~s(Login says "signed_in"))

      assert PostSummary.error(post) == "Error: signed_in_twice is not allowed."
    end
  end

  describe "a body read once for a page" do
    # Every result is the one a process that had read nothing would give.
    defp afresh(fun, post), do: fn -> fun.(post) end |> Task.async() |> Task.await()

    property "never answers for another post, or for this post before an edit" do
      body =
        member_of([
          "```\nError: first thing broke.\n```\n\n**Fix:** restart the first thing today.",
          "```\nError: second thing broke.\n```\n\n**Fix:** restart the second thing today.",
          "Nothing in code here, only words."
        ])

      post =
        gen all(id <- member_of(Enum.map(1..3, fn _ -> Ash.UUID.generate() end)), body <- body) do
          %{
            id: id,
            thread_kind: :help_needed,
            title: "Something broke",
            note: nil,
            tool_names: [],
            site: @site,
            body_markdown: body
          }
        end

      reading =
        member_of([&PostSummary.headline/1, &PostSummary.description/1, &PostSummary.error/1])

      check all(reads <- list_of(tuple({post, reading}), min_length: 2, max_length: 12)) do
        for {post, fun} <- reads, do: assert(fun.(post) == afresh(fun, post))
      end
    end

    test "two posts with the same id and different words are each read for their own" do
      id = Ash.UUID.generate()
      first = %{written("```\nError: first thing broke.\n```\n") | id: id}
      edited = %{written("```\nError: second thing broke.\n```\n") | id: id}

      assert PostSummary.error(first) == "Error: first thing broke."
      assert PostSummary.error(edited) == "Error: second thing broke."
      assert PostSummary.error(first) == "Error: first thing broke."
    end
  end

  describe "a report's page" do
    setup do
      site = ErrorReports.site!()
      %{post: ErrorReports.post!(site, ErrorReports.get!("entra_aadsts9010010"))}
    end

    test "leads its title and description with the error", %{conn: conn, post: post} do
      html = conn |> get(PostAddress.path(post)) |> html_response(200)

      description =
        PostSummary.description(post)
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      assert [_, title] = Regex.run(~r{<title[^>]*>\s*(.*?)\s*</title>}s, html)

      assert title =~
               ~r/\Ainvalid_target AADSTS9010010: The resource parameter provided in the… · Patchbay\z/

      assert html =~ ~s(<meta name="description" content="#{description}">)
      assert html =~ ~s(<meta property="og:description" content="#{description}">)
      assert html =~ ~s(<meta name="twitter:description" content="#{description}">)
      assert description =~ ~r/\Ainvalid_target AADSTS9010010: /
    end

    test "a title that quotes the error puts it first in the tab and the address", %{conn: conn} do
      post = ErrorReports.post!(ErrorReports.site!(), ErrorReports.get!("touch_id"))
      path = PostAddress.path(post)
      assert path =~ ~r|\A/posts/[0-9a-f-]{36}/no_touch_id-regents-auth-login-on-a-mac-|

      html = conn |> get(path) |> html_response(200)
      assert [_, title] = Regex.run(~r{<title[^>]*>\s*(.*?)\s*</title>}s, html)
      assert title =~ ~r/\Ano_touch_id — regents auth login on a Mac: .* · Patchbay\z/
    end

    test "tells search engines the question is about that error", %{conn: conn, post: post} do
      html = conn |> get(PostAddress.path(post)) |> html_response(200)

      [json] =
        Regex.run(~r{<script type="application/ld\+json">\s*(.*?)\s*</script>}s, html,
          capture: :all_but_first
        )

      %{"@graph" => graph} = Jason.decode!(json)
      page = Enum.find(graph, &(&1["@type"] == "QAPage"))

      assert page["url"] == PostAddress.url(post)
      assert page["mainEntity"]["name"] == post.title
      assert page["mainEntity"]["description"] == PostSummary.description(post)
      assert page["mainEntity"]["description"] =~ "AADSTS9010010"
    end
  end
end
