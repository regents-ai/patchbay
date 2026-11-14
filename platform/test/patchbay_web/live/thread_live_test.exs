defmodule PatchbayWeb.ThreadLiveTest do
  # A reader's own presses on a post's page change it where it stands
  # (`PatchbayWeb.ThreadLive`): the heart, the follow bell and the asker's
  # mark. A refused press says why beside what was pressed.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.Principal
  alias Patchbay.Identity
  alias PatchbayWeb.LivePart
  alias PatchbayWeb.ThreadLive

  setup do
    site = Forum.register_site!("presses.example")
    asker = person("asker")
    post = ask(site, asker)
    reply = reply(post, person("replier"))
    %{site: site, asker: asker, post: post, reply: reply}
  end

  describe "the heart" do
    test "likes and takes back a like on the post and on a reply, with its count and names", %{
      conn: conn,
      post: post,
      reply: reply
    } do
      reader = person("reader")
      view = conn |> signed_in(reader) |> open(post)

      for heart <- ["#pb-post", "#reply-#{reply.id}"] do
        view |> element("#{heart} .rg-discussion__heart") |> render_click()

        assert pressed(view, heart) == "true"
        assert view |> element("#{heart} .rg-figure") |> render() =~ "1"
        assert view |> element("#{heart} .rg-discussion__liked-by") |> render() =~ "Liked by"

        view |> element("#{heart} .rg-discussion__heart") |> render_click()

        assert pressed(view, heart) == "false"
        refute has_element?(view, "#{heart} .rg-figure")
        refute has_element?(view, "#{heart} .rg-discussion__liked-by")
      end

      assert Forum.list_my_likes!(post.id, actor: reader) == []
    end

    test "the same press sent twice ends where it was last pressed", %{conn: conn, post: post} do
      reader = person("reader")
      view = conn |> signed_in(reader) |> open(post)

      for _twice <- 1..2, do: render_click(view, "like", %{"like" => "true"})

      assert pressed(view, "#pb-post") == "true"
      assert [%{reply_id: nil}] = Forum.list_my_likes!(post.id, actor: reader)
    end

    test "signed out, it says to sign in where it was pressed, and nothing is saved", %{
      conn: conn,
      post: post
    } do
      view = open(conn, post)
      view |> element("#pb-post .rg-discussion__heart") |> render_click()

      assert view |> element("#pb-post-refused[role=alert]") |> render() =~
               "Sign in at the top of the page to like posts."

      assert pressed(view, "#pb-post") == "false"
      assert Forum.get_report!(post.id, load: [:post_like_count]).post_like_count == 0
    end

    test "once the reader is suspended, it says so where it was pressed, and nothing is saved",
         %{conn: conn, post: post, reply: reply} do
      reader = person("reader")
      view = conn |> signed_in(reader) |> open(post)
      Identity.suspend_profile!(reader, "Spam", actor: %{role: :system})

      view |> element("#reply-#{reply.id} .rg-discussion__heart") |> render_click()

      assert view |> element("#reply-#{reply.id}-refused[role=alert]") |> render() =~
               "Sign in at the top of the page to like posts."

      assert pressed(view, "#reply-#{reply.id}") == "false"
      assert Forum.list_my_likes!(post.id, actor: reader) == []
    end

    test "a press that is saved takes away the last refusal", %{
      conn: conn,
      post: post,
      reply: reply
    } do
      view = conn |> signed_in(person("reader")) |> open(post)
      render_click(view, "mark_solution", %{"reply" => reply.id})
      assert has_element?(view, "#reply-#{reply.id}-refused")

      view |> element("#pb-post .rg-discussion__heart") |> render_click()

      refute has_element?(view, ".pb-press-refused")
      assert pressed(view, "#pb-post") == "true"
    end
  end

  describe "the follow bell" do
    test "follows the post's site and stops, for the browser when no one is signed in", %{
      conn: conn,
      site: site,
      post: post
    } do
      page = get(conn, PostAddress.path(post))
      browser = Principal.for_session(get_session(page, "forum_session_id"))
      view = join(page)

      view |> element(".pb-follow-bell") |> render_click()
      assert view |> element(".pb-follow-bell") |> render() =~ ~s(aria-pressed="true")
      assert follows(browser) == [site.id]

      view |> element(".pb-follow-bell") |> render_click()
      assert view |> element(".pb-follow-bell") |> render() =~ ~s(aria-pressed="false")
      assert follows(browser) == []
    end

    test "follows for the signed-in person, and the next read of the page shows it", %{
      conn: conn,
      site: site,
      post: post
    } do
      reader = person("reader")
      conn = signed_in(conn, reader)
      view = open(conn, post)

      view |> element(".pb-follow-bell") |> render_click()

      assert view |> element(".pb-follow-bell") |> render() =~ ~s(aria-pressed="true")
      assert follows(Principal.for_profile(reader.id)) == [site.id]

      assert conn |> open(post) |> element(".pb-follow-bell") |> render() =~
               ~s(aria-pressed="true")
    end
  end

  test "on the open address, the heart and the bell change the page in place too", %{
    conn: conn,
    site: site,
    post: post
  } do
    reader = person("reader")
    view = conn |> on_open() |> signed_in(reader) |> open(post)

    view |> element("#pb-post .rg-discussion__heart") |> render_click()
    view |> element(".pb-follow-bell") |> render_click()

    assert pressed(view, "#pb-post") == "true"
    assert view |> element(".pb-follow-bell") |> render() =~ ~s(aria-pressed="true")
    assert [%{reply_id: nil}] = Forum.list_my_likes!(post.id, actor: reader)
    assert follows(Principal.for_profile(reader.id)) == [site.id]
  end

  describe "the asker's mark" do
    test "names the answer where it stands", %{conn: conn, asker: asker, post: post, reply: reply} do
      view = conn |> signed_in(asker) |> open(post)

      view |> element("#reply-#{reply.id} button", "This answered it") |> render_click()

      assert has_element?(view, "#pb-fix")
      assert has_element?(view, "#reply-#{reply.id}.rg-discussion__post--solution")
      refute has_element?(view, "button", "This answered it")
      assert Forum.get_report!(post.id).solution_reply_id == reply.id
    end

    test "from anyone else, says why beside the reply, and marks nothing", %{
      conn: conn,
      post: post,
      reply: reply
    } do
      view = conn |> signed_in(person("reader")) |> open(post)

      render_click(view, "mark_solution", %{"reply" => reply.id})

      assert view |> element("#reply-#{reply.id}-refused[role=alert]") |> render() =~
               "Only whoever asked this question can say which answer worked."

      assert Forum.get_report!(post.id).solution_reply_id == nil
    end
  end

  # The post page's live part, joined as the browser that opened it.
  defp open(conn, post), do: conn |> get(PostAddress.path(post)) |> join()

  defp join(page) do
    session = page |> html_response(200) |> LivePart.session(ThreadLive)
    {:ok, view, _html} = live_isolated(LivePart.browser(page), ThreadLive, session: session)
    view
  end

  defp pressed(view, post) do
    view
    |> element("#{post} .rg-discussion__heart")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("aria-pressed")
    |> hd()
  end

  defp follows(principal) do
    principal
    |> List.wrap()
    |> Forum.list_subscriptions_for_principals!(actor: %{principals: [principal]})
    |> Enum.map(& &1.scope_id)
  end

  defp signed_in(conn, profile) do
    sign_in(conn, profile.id)
  end

  # Written as the board's own requests write them; who may post is not under test.
  defp ask(site, author) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        title: "Why does the cart empty itself?",
        thread_kind: :help_needed,
        body_markdown: "What I tried: everything.",
        browser_session_id: Ash.UUID.generate()
      },
      actor: author,
      private_arguments: %{author_kind: :human}
    )
  end

  defp reply(post, author) do
    Forum.post_human_reply!(
      %{report_id: post.id, browser_session_id: Ash.UUID.generate(), body_markdown: "Clear it."},
      actor: author
    )
  end

  defp person(name) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:presses-" <> name,
      wallet_address: "0x" <> (:crypto.hash(:sha, name) |> Base.encode16(case: :lower))
    })
  end
end
