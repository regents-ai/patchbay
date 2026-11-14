defmodule PatchbayWeb.PostFormLiveTest do
  # The post form on the home page, an agent page and a site page's window
  # (`PatchbayWeb.PostFormLive`): a press is answered where the form stands,
  # what was typed and the pictures chosen stay through a refusal, and a
  # published post opens its own page with its pictures.
  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.PostPicture
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.Site
  alias Patchbay.Identity
  alias Patchbay.JevStandIn
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Hero
  alias PatchbayWeb.LivePart
  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.PostFormLive

  @typed %{"goal" => "Where does a declined card go?", "site_url" => "checkout.example/cart"}

  # Tools are listed by the page's script once it finds them, so a press
  # carries the picked ones as the browser sends them.
  @tools %{"ask" => %{"tools" => ["add_to_cart"]}}

  describe "drawn on a page" do
    test "the home page, an agent page and a site page each keep their own draft", %{conn: conn} do
      for {path, home} <- [
            {"/", "/"},
            {"/hermes", "/hermes"},
            {"/checkout.example", "/checkout.example"}
          ] do
        session = conn |> get(path) |> html_response(200) |> LivePart.session(PostFormLive)
        assert session["home"] == home
      end
    end

    test "its text fields take nothing until the form is connected, and take text once it is",
         %{conn: conn} do
      fields = ~w(#pb-fix-goal #pb-fix-site #pb-hero-body #pb-hero-tags)
      page = conn |> get("/hermes") |> html_response(200) |> LazyHTML.from_document()
      view = open(conn, "/hermes")

      for field <- fields do
        assert page |> LazyHTML.query(field) |> LazyHTML.attribute("readonly") == [""]

        assert view
               |> element(field)
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.attribute("readonly") ==
                 []
      end
    end

    test "a site page opens its form with the site and the words from the link", %{conn: conn} do
      view = open(conn, "/checkout.example?page=checkout.example/cart&goal=Pay&error=Declined")

      assert input_value(view, "#pb-fix-site") =~ "checkout.example/cart"
      assert input_value(view, "#pb-fix-goal") == "Pay"
      assert view |> element("#pb-hero-body") |> render() =~ "Declined"
    end
  end

  describe "publishing" do
    test "previews, publishes exactly what was shown with its pictures in order, and opens the post",
         %{conn: conn} do
      asker = person("asker")
      view = conn |> signed_in(asker) |> open("/")

      typed =
        Map.merge(@typed, %{
          "details" =>
            "I tried twice and the cart stayed empty. My key was sk-abcdefghijklmnopqrstuvwxyz.",
          "topic_tags" => "Checkout, Cards"
        })

      type(view, typed)
      pictures = Enum.map(~w(first second third), &png/1)
      upload = choose(view, pictures)

      press(view, "data-pb-preview", @tools)
      assert has_element?(view, "#pb-hero-post")
      assert has_element?(view, "#pb-hero-post .pb-ask-flags")

      assert view |> element("#pb-hero-post .pb-post-pictures") |> render() =~
               "Picture 3 you added"

      assert Forum.list_recent_reports!().results == []

      # A press carrying words changed since the preview shows them again
      # rather than posting them.
      press(
        view,
        "data-pb-post",
        put_in(@tools, ["ask", "goal"], "Where does a refused card go?")
      )

      assert view |> element("#pb-hero-post h3") |> render() =~ "Where does a refused card go?"
      assert Forum.list_recent_reports!().results == []

      type(view, typed)
      press(view, "data-pb-preview", @tools)
      upload_all(upload)

      assert {:error, {:redirect, %{to: path}}} = press(view, "data-pb-post", @tools)
      [_, id] = Regex.run(~r{^/posts/([^/]+)/}, path)

      thread = Ash.load!(Ash.get!(Report, id), :pictures)
      assert thread.thread_kind == :help_needed
      assert thread.author_profile_id == asker.id
      assert thread.author_kind == :human
      assert thread.topic_tags == ["checkout", "cards"]
      assert thread.tool_names == ["add_to_cart"]
      assert thread.page_url == "https://checkout.example/cart"

      assert Enum.map(thread.pictures, &{&1.position, &1.image}) ==
               Enum.with_index(pictures, fn picture, at -> {at, picture.content} end)

      [first | _] = thread.pictures
      page = conn |> signed_in(asker) |> get(path) |> html_response(200)
      assert page =~ ~s(src="/post-pictures/#{first.id}")

      shown = build_conn() |> get(~p"/post-pictures/#{first.id}")
      assert response(shown, 200) == hd(pictures).content
      assert get_resp_header(shown, "content-type") == ["image/png"]
    end

    test "a publish the reading turns away keeps the pictures and the words, says why beside the form, and the next press posts them",
         %{conn: conn} do
      view = conn |> signed_in(person("asker")) |> open("/")
      type(view, @typed)
      pictures = Enum.map(~w(left right), &png/1)
      upload = choose(view, pictures)
      press(view, "data-pb-preview")
      upload_all(upload)

      JevStandIn.finds("too_short", 0.92)
      press(view, "data-pb-post")

      assert has_element?(view, "#pb-hero-refused[role=alert]")

      refute view
             |> element("#pb-hero-refused")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text() == ""

      assert picture_names(view) == ["left.png", "right.png"]
      assert input_value(view, "#pb-fix-goal") == @typed["goal"]
      assert input_value(view, "#pb-fix-site") == @typed["site_url"]
      assert has_element?(view, "#pb-hero-post")
      assert Forum.list_recent_reports!().results == []

      JevStandIn.accept_posts()
      assert {:error, {:redirect, %{to: path}}} = press(view, "data-pb-post")
      [_, id] = Regex.run(~r{^/posts/([^/]+)/}, path)

      assert Ash.load!(Ash.get!(Report, id), :pictures).pictures |> Enum.map(& &1.image) ==
               Enum.map(pictures, & &1.content)
    end

    test "a refusal over one field is said under it before the post is read, keeps the pictures, and opens no board",
         %{conn: conn} do
      view = conn |> signed_in(person("asker")) |> open("/")
      type(view, %{@typed | "site_url" => "not a web address"})
      upload = choose(view, [png("kept")])
      press(view, "data-pb-preview")
      upload_all(upload)

      # Were the post read first, this reading would turn it away beside the
      # form instead.
      JevStandIn.finds("too_short", 0.92)
      press(view, "data-pb-post")

      assert_push_event(view, "pb:reach", %{to: "pb-fix-site", line: "pb-fix-site-errors"})
      assert attribute(view, "#pb-fix-site", "aria-invalid") == "true"

      assert "pb-fix-site-errors" in String.split(
               attribute(view, "#pb-fix-site", "aria-describedby")
             )

      assert attribute(view, "#pb-fix-goal", "aria-invalid") == "false"
      refute has_element?(view, "#pb-hero-refused")
      assert picture_names(view) == ["kept.png"]
      assert input_value(view, "#pb-fix-site") == "not a web address"
      assert Forum.list_recent_reports!().results == []
      assert Ash.read!(Site, authorize?: false) == []
    end

    test "signed out, publishing says to sign in beside the form and keeps the words", %{
      conn: conn
    } do
      view = open(conn, "/")
      refute has_element?(view, "#pb-hero-pictures-box")
      type(view, @typed)
      press(view, "data-pb-preview")
      press(view, "data-pb-post")

      assert has_element?(view, "#pb-hero-refused[role=alert]")
      refute has_element?(view, "[aria-invalid=true]")
      assert input_value(view, "#pb-fix-goal") == @typed["goal"]
      assert Forum.list_recent_reports!().results == []
      assert Board.fetch_site_ref("checkout.example") == :error
    end

    test "a profile signed out after the page opened cannot post", %{conn: conn} do
      asker = person("asker")
      view = conn |> signed_in(asker) |> open("/")
      type(view, @typed)
      press(view, "data-pb-preview")
      Identity.suspend_profile!(asker, "Spam", actor: %{role: :system})
      press(view, "data-pb-post")

      assert has_element?(view, "#pb-hero-refused[role=alert]")
      assert Forum.list_recent_reports!().results == []
    end
  end

  describe "the lines under the fields" do
    test "an empty issue and site are said under each, and typing takes each away once right",
         %{conn: conn} do
      view = open(conn, "/")
      press(view, "data-pb-preview")

      assert_push_event(view, "pb:reach", %{to: "pb-fix-goal", line: "pb-fix-goal-errors"})
      assert attribute(view, "#pb-fix-goal", "aria-invalid") == "true"
      assert attribute(view, "#pb-fix-site", "aria-invalid") == "true"
      refute has_element?(view, "#pb-hero-post")

      type(view, %{"goal" => "Pay", "site_url" => ""}, ["ask", "goal"])
      assert attribute(view, "#pb-fix-goal", "aria-invalid") == "false"
      assert attribute(view, "#pb-fix-site", "aria-invalid") == "true"
    end

    test "a title too long is said under it once it is left, and on a press, not as it is typed",
         %{conn: conn} do
      view = open(conn, "/")
      long = String.duplicate("a", Hero.max_title() + 1)

      type(view, %{@typed | "goal" => long}, ["ask", "goal"])
      assert attribute(view, "#pb-fix-goal", "aria-invalid") == "false"

      view |> element("#pb-fix-goal") |> render_blur(%{"value" => long})
      assert attribute(view, "#pb-fix-goal", "aria-invalid") == "true"

      press(view, "data-pb-preview")
      assert view |> element("#pb-fix-goal-errors") |> render() =~ Hero.title_fix()
      refute has_element?(view, "#pb-hero-post")

      type(view, @typed, ["ask", "goal"])
      assert attribute(view, "#pb-fix-goal", "aria-invalid") == "false"
    end
  end

  describe "pictures" do
    test "another kind or one too large is not added, and the line says why", %{conn: conn} do
      view = conn |> signed_in(person("asker")) |> open("/")

      choose(view, [
        %{name: "notes.txt", content: "not a picture", type: "text/plain"},
        %{
          name: "large.png",
          content: :binary.copy("x", PostPicture.max_bytes() + 1),
          type: "image/png"
        }
      ])

      assert picture_names(view) == []
      assert view |> element("#pb-hero-pictures-errors") |> render() =~ "<p>"
    end

    test "past four, the first four are kept; full, Add pictures says to remove one, and Remove frees a place",
         %{conn: conn} do
      view = conn |> signed_in(person("asker")) |> open("/")
      choose(view, Enum.map(~w(one two three four five), &png/1))

      assert picture_names(view) == ~w(one.png two.png three.png four.png)
      kept_said = view |> element("#pb-hero-pictures-errors") |> render()
      assert kept_said =~ "<p>"
      assert attribute(view, "#pb-hero-pictures-add", "aria-disabled") == "true"

      view |> element("#pb-hero-pictures-add") |> render_click()
      assert_push_event(view, "pb:reach", %{to: "pb-hero-pictures-add"})
      refute view |> element("#pb-hero-pictures-errors") |> render() == kept_said

      view |> element("#pb-hero-picture-item-#{ref_of(view, "two.png")} button") |> render_click()
      assert picture_names(view) == ~w(one.png three.png four.png)
      assert attribute(view, "#pb-hero-pictures-add", "aria-disabled") == "false"
      refute view |> element("#pb-hero-pictures-errors") |> render() =~ "<p>"
    end
  end

  # The page at `path` as the browser opens it, joined to its post form.
  defp open(conn, path) do
    page = get(conn, path)
    session = page |> html_response(200) |> LivePart.session(PostFormLive)
    {:ok, view, _html} = live_isolated(LivePart.browser(page), PostFormLive, session: session)
    view
  end

  # Typed into the form, as the page sends each change.
  defp type(view, typed, target \\ ["ask", "goal"]) do
    view |> form("#pb-hero-form", ask: typed) |> render_change(%{"_target" => target})
  end

  # Chosen with Add pictures: the form hears of them as the browser tells it.
  defp choose(view, files) do
    upload = file_input(view, "#pb-hero-form", :pictures, files)
    view |> element("#pb-hero-form") |> render_change(upload)
    upload
  end

  # The pictures go up as the browser sends them with a press.
  defp upload_all(upload),
    do: for(%{"name" => name} <- upload.entries, do: render_upload(upload, name))

  defp press(view, button, values \\ %{}) do
    view
    |> form("#pb-hero-form")
    |> put_submitter("button[#{button}]")
    |> render_submit(values)
  end

  defp png(words),
    do: %{
      name: "#{words}.png",
      content: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, words::binary>>,
      type: "image/png"
    }

  defp picture_names(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".pb-picture img")
    |> LazyHTML.attribute("alt")
  end

  defp ref_of(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(.pb-picture img[alt="#{name}"]))
    |> LazyHTML.attribute("data-phx-entry-ref")
    |> hd()
  end

  defp attribute(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> hd()
  end

  defp input_value(view, selector), do: attribute(view, selector, "value")

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id, System.os_time(:second))
  end

  defp person(name) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:post-form-" <> name,
      wallet_address: "0x" <> (:crypto.hash(:sha, name) |> Base.encode16(case: :lower))
    })
  end
end
