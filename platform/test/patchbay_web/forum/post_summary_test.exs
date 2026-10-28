defmodule PatchbayWeb.Forum.PostSummaryTest do
  @moduledoc """
  A report's page leads with the error it is about, word for word: in its tab
  title, its search description and what it tells search engines it holds.
  Checked on eight real reports.
  """

  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.ErrorReports
  alias PatchbayWeb.Forum.PostAddress
  alias PatchbayWeb.Forum.PostSummary

  # What a searcher pastes from each error, and whether the post quotes the
  # error in a code block.
  @searched %{
    "draft_07_output_schema" => {"unsupported dialect", :quoted},
    "entra_aadsts9010010" => {"AADSTS9010010", :quoted},
    "keyfleet_git_401" => {"Git needs a password for this fleet's code", :quoted},
    "keyfleet_join" => {"not_signed_in: Sign in first", :quoted},
    "touch_id" => {"no_touch_id", :title},
    "webmcp_model_context" =>
      {"Cannot read properties of undefined (reading 'registerTool')", :quoted},
    "x402_header_overflow" => {"UND_ERR_HEADERS_OVERFLOW", :quoted},
    "x402_payment_signature" => {"PAYMENT-SIGNATURE", :title}
  }

  defp shown(report), do: Map.merge(report, %{id: Ash.UUID.generate(), note: nil, tool_names: []})

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

  test "the tab title is the report's title, cut between words" do
    for report <- ErrorReports.all() do
      title = report |> shown() |> PostSummary.title()

      assert String.length(title) <= 70
      assert String.starts_with?(report.title, String.trim_trailing(title, "…"))
    end
  end

  test "a post with no body is described by its own words" do
    post = %{
      id: Ash.UUID.generate(),
      title: nil,
      body_markdown: nil,
      tool_names: [],
      note: "The cart stayed empty."
    }

    assert PostSummary.description(post) == "The cart stayed empty."
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
               ~r/\AClaude Code MCP OAuth to Entra ID fails with AADSTS9010010.* · Patchbay\z/

      assert html =~ ~s(<meta name="description" content="#{description}">)
      assert html =~ ~s(<meta property="og:description" content="#{description}">)
      assert html =~ ~s(<meta name="twitter:description" content="#{description}">)
      assert description =~ ~r/\Ainvalid_target AADSTS9010010: /
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
