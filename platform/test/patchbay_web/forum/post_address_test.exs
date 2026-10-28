defmodule PatchbayWeb.Forum.PostAddressTest do
  @moduledoc """
  A post's address carries the words of its title, and every other address
  with its id moves there for good, keeping what the reader asked for.
  """

  use PatchbayWeb.ConnCase, async: false
  use ExUnitProperties

  alias PatchbayWeb.ErrorReports
  alias PatchbayWeb.Forum.PostAddress

  describe "the words of an address" do
    test "are the title's words, lowercase and joined by hyphens" do
      assert PostAddress.slug(~s(regents keyfleet: "not_signed_in", then agent_not_paired)) ==
               "regents-keyfleet-not-signed-in-then-agent-not-paired"

      assert PostAddress.slug("Keyfleet git: \"Git needs a password for this fleet's code\"") ==
               "keyfleet-git-git-needs-a-password-for-this-fleets-code"

      assert PostAddress.slug("Café crème à la carte") == "cafe-creme-a-la-carte"
    end

    test "stop between words at 80 characters" do
      slug =
        PostAddress.slug(
          "Claude Desktop rejects every MCP tool: \"outputSchema ... unsupported dialect (draft-07)\". Cause and working fix"
        )

      assert slug ==
               "claude-desktop-rejects-every-mcp-tool-outputschema-unsupported-dialect-draft-07"

      assert PostAddress.slug(String.duplicate("a", 200)) == String.duplicate("a", 80)
    end

    test "are post when the title has no letters or digits it can use" do
      assert PostAddress.slug("支付失败") == "post"
      assert PostAddress.slug("…") == "post"
    end

    property "are always lowercase words and hyphens, at most 80 characters" do
      check all(title <- string(:printable, max_length: 300)) do
        slug = PostAddress.slug(title)

        assert slug =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
        assert String.length(slug) <= 80
      end
    end
  end

  describe "a post's page" do
    setup do
      post = ErrorReports.post!(ErrorReports.site!(), ErrorReports.get!("keyfleet_join"))
      %{post: post, path: PostAddress.path(post)}
    end

    test "answers at its own address", %{conn: conn, post: post, path: path} do
      assert path ==
               "/posts/#{post.id}/regents-keyfleet-not-signed-in-then-agent-not-paired-or-person-not-here-what"

      html = conn |> get(path) |> html_response(200)
      assert html =~ ~s(<link rel="canonical" href="#{PostAddress.url(post)}">)
    end

    test "moves there for good from its id alone, other words and the earlier address", %{
      conn: conn,
      post: post,
      path: path
    } do
      for old <- [
            "/posts/#{post.id}",
            "/posts/#{post.id}/an-older-title",
            "/posts/#{post.id}/post",
            "/posts/#{String.upcase(post.id)}/an-older-title",
            "/reports/#{post.id}"
          ] do
        moved = get(conn, old)
        assert moved.status == 301, old
        assert redirected_to(moved, 301) == path
      end
    end

    test "keeps the query on the way", %{conn: conn, post: post, path: path} do
      moved = get(conn, "/reports/#{post.id}?replies=solution&after=abc")
      assert redirected_to(moved, 301) == path <> "?replies=solution&after=abc"

      moved = get(conn, "/posts/#{post.id}/wrong?replies=all")
      assert redirected_to(moved, 301) == path <> "?replies=all"
    end

    test "a move counts no view; the page itself does", %{conn: conn, post: post, path: path} do
      # Views are counted for the board, not read by any visitor's policy.
      get(conn, "/posts/#{post.id}")
      assert Ash.load!(post, :view_count, authorize?: false).view_count == 0

      get(conn, path)
      assert Ash.load!(post, :view_count, authorize?: false).view_count == 1
    end

    test "an id that names no post is a missing page", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/posts/#{Ash.UUID.generate()}/some-words") end)
      assert_error_sent(404, fn -> get(conn, "/posts/not-an-id/some-words") end)
    end

    test "is the address the sitemap, the feed and the API give", %{conn: conn, post: post} do
      url = PostAddress.url(post)

      assert conn |> get("/sitemap.xml") |> response(200) =~ "<loc>#{url}</loc>"
      assert conn |> get("/") |> html_response(200) =~ ~s(href="#{PostAddress.path(post)}")

      thread = conn |> get("/forum/threads/#{post.id}") |> json_response(200)
      assert thread["report"]["url"] == PostAddress.path(post)
    end
  end
end
