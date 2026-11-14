defmodule PatchbayWeb.ModerationLiveTest do
  @moduledoc """
  The moderation page's presses (`PatchbayWeb.ModerationLive`): each decision
  changes the page where it stands, under the moderator's own name, and none
  reaches anyone who is not a moderator, whether they join the page's live
  part themselves or stop being a moderator while it is open.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.ModerationAction
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PostCheck
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Identity
  alias PatchbayWeb.LivePart
  alias PatchbayWeb.ModerationLive

  describe "a record" do
    test "Hold keeps a thread out of every public view, with its reason on record, and the page shows it waiting",
         %{conn: conn} do
      thread = thread!()
      moderator = moderator()
      view = open(conn, moderator)

      moderate(view, "thread-#{thread.id}", "quarantine", "Read like an advertisement.")

      assert has_element?(view, "#pb-mod-held-thread-#{thread.id}-decide button[value=publish]")
      refute has_element?(view, "#pb-mod-thread-#{thread.id}")
      assert view |> element("#pb-mod-decisions") |> render() =~ "Read like an advertisement."
      # The test reads its own records back, held or not.
      assert Ash.get!(Report, thread.id, authorize?: false).visibility == :quarantined

      # Publicly the thread answers like one that does not exist, everywhere.
      assert_error_sent(404, fn -> get(build_conn(), PostAddress.path(thread)) end)
      refute build_conn() |> get(~p"/") |> html_response(200) =~ thread.title
      refute build_conn() |> get(~p"/shop.example") |> html_response(200) =~ thread.title

      assert json_response(get(build_conn(), "/forum/search", %{"q" => "declined cards"}), 200)[
               "results"
             ] == []

      assert json_response(get(build_conn(), "/forum/threads/#{thread.id}"), 404)["error"][
               "code"
             ] == "not_found"

      assert [%{action: :quarantine, subject_id: id, actor_profile_id: actor, reason: reason}] =
               Ash.read!(ModerationAction, authorize?: false)

      assert {id, actor, reason} == {thread.id, moderator.id, "Read like an advertisement."}
    end

    test "Put back returns a held thread to public view, and Remove keeps a held reply out for good",
         %{conn: conn} do
      thread = thread!()
      reply = reply!(thread)
      moderator = moderator()
      {:ok, _held} = Forum.moderate(thread, :quarantine, "Held for a look.", moderator)
      {:ok, _held} = Forum.moderate(reply, :quarantine, "Held for a look.", moderator)
      view = open(conn, moderator)

      moderate(view, "held-thread-#{thread.id}", "publish", "Fine after all.")
      assert has_element?(view, "#pb-mod-thread-#{thread.id}-decide button[value=quarantine]")
      refute has_element?(view, "#pb-mod-held-thread-#{thread.id}")
      assert Ash.get!(Report, thread.id, authorize?: false).visibility == :published

      assert build_conn() |> get(PostAddress.path(thread)) |> html_response(200) =~
               thread.title

      moderate(view, "held-reply-#{reply.id}", "redact", "Spam.")
      refute has_element?(view, "#pb-mod-held-reply-#{reply.id}")
      assert Ash.get!(Reply, reply.id, authorize?: false).visibility == :redacted

      assert ModerationAction
             |> Ash.read!(authorize?: false)
             |> Enum.map(& &1.action)
             |> Enum.sort() ==
               [:publish, :quarantine, :quarantine, :redact]
    end

    test "Remove takes a published thread out for good", %{conn: conn} do
      thread = thread!()
      view = open(conn, moderator())

      moderate(view, "thread-#{thread.id}", "redact", "Spam.")

      refute has_element?(view, "#pb-mod-thread-#{thread.id}")
      assert Ash.get!(Report, thread.id, authorize?: false).visibility == :redacted
    end
  end

  describe "a post turned away" do
    test "is ruled right, cleared, then ruled wrong, each said on its row", %{conn: conn} do
      check = turned_away!(person!("ruled"))
      view = open(conn, moderator())

      review(view, check, "right")
      assert ruling(check) == :right
      assert has_element?(view, "#pb-mod-post-#{check.id} .pb-mod-state")
      assert has_element?(view, "#pb-mod-post-#{check.id} button[phx-value-action=none]")

      review(view, check, "none")
      assert ruling(check) == nil
      refute has_element?(view, "#pb-mod-post-#{check.id} .pb-mod-state")

      review(view, check, "wrong")
      assert ruling(check) == :wrong

      assert ModerationAction
             |> Ash.read!(authorize?: false)
             |> Enum.map(& &1.action)
             |> Enum.sort() ==
               [:right_to_block, :ruling_withdrawn, :wrong_to_block]
    end

    test "becomes an example and stops being one", %{conn: conn} do
      check = turned_away!(person!("example"))
      view = open(conn, moderator())
      review(view, check, "right")

      review(view, check, "example")
      assert is_binary(Forum.get_post_check!(check.id, authorize?: false).example)
      assert has_element?(view, "#pb-mod-post-#{check.id} button[phx-value-action=no_example]")
      refute has_element?(view, "#pb-mod-post-#{check.id} button[phx-value-action=example]")

      review(view, check, "no_example")
      assert Forum.get_post_check!(check.id, authorize?: false).example == nil
      assert has_element?(view, "#pb-mod-post-#{check.id} button[phx-value-action=example]")
    end

    test "Lift pause lets the person post again, and the pause leaves each of their rows",
         %{conn: conn} do
      person = person!("paused")
      checks = for _each <- 1..3, do: turned_away!(person)
      view = open(conn, moderator())
      [first | _rest] = checks

      assert has_element?(view, "#pb-mod-post-#{first.id} button[phx-value-action=lift]")

      review(view, first, "lift")

      refute has_element?(view, "button[phx-value-action=lift]")

      assert Enum.all?(
               checks,
               &(Forum.get_post_check!(&1.id, authorize?: false).lifted_at != nil)
             )

      assert [%{action: :pause_lifted, subject_id: subject}] =
               Ash.read!(ModerationAction, authorize?: false)

      assert subject == person.id
    end

    test "a press refused says why beside it, and nothing is recorded", %{conn: conn} do
      check = turned_away!(person!("unruled"))
      view = open(conn, moderator())

      # Only a ruled post can be an example, whatever the page showed.
      render_click(view, "review", %{"kind" => "post", "id" => check.id, "action" => "example"})

      assert has_element?(view, "#pb-mod-post-#{check.id}-refused[role=alert]")
      assert Forum.get_post_check!(check.id, authorize?: false).example == nil
      assert Ash.read!(ModerationAction, authorize?: false) == []

      review(view, check, "right")
      refute has_element?(view, "#pb-mod-post-#{check.id}-refused")
    end
  end

  describe "anyone not a moderator" do
    test "joining the page's live part with another sign-in is answered as though it is not there",
         %{conn: conn} do
      page = conn |> sign_in(moderator().id) |> get(~p"/moderation")
      session = page |> html_response(200) |> LivePart.session(ModerationLive)

      # Joined from a browser with no sign-in, the page is loaded again and
      # answered as an address that is not there.
      assert {%{reason: "reload", status: 404}, _call} =
               catch_exit(
                 page
                 |> joined_with(%{})
                 |> live_isolated(ModerationLive, session: session)
               )

      # Another person's sign-in is not the one the page was drawn for, so the
      # page is loaded again from its address, which is not there for them.
      cookie = signed_in_session(person!("stranger").id)

      assert {:error, {:redirect, %{to: "/moderation"}}} =
               page |> joined_with(cookie) |> live_isolated(ModerationLive, session: session)

      assert (build_conn() |> init_test_session(cookie) |> get(~p"/moderation")).status == 404
    end

    test "a moderator taken off the list while the page is open: each press goes to the front page and decides nothing",
         %{conn: conn} do
      thread = thread!()
      held = thread!(%{title: "Held while the list changed"})
      check = turned_away!(person!("kept"))
      moderator = moderator()
      {:ok, _held} = Forum.moderate(held, :quarantine, "Held for a look.", moderator)
      listed = Application.get_env(:patchbay, :moderator_wallets)

      presses = [
        {"moderate",
         %{"subject" => %{"kind" => "thread", "id" => thread.id, "action" => "quarantine"}}},
        {"moderate",
         %{"subject" => %{"kind" => "thread", "id" => thread.id, "action" => "redact"}}},
        {"moderate",
         %{"subject" => %{"kind" => "thread", "id" => held.id, "action" => "publish"}}},
        {"review", %{"kind" => "post", "id" => check.id, "action" => "right"}},
        {"review", %{"kind" => "post", "id" => check.id, "action" => "wrong"}},
        {"review", %{"kind" => "post", "id" => check.id, "action" => "none"}},
        {"review", %{"kind" => "post", "id" => check.id, "action" => "example"}},
        {"review", %{"kind" => "post", "id" => check.id, "action" => "no_example"}},
        {"review", %{"kind" => "person", "id" => check.profile_id, "action" => "lift"}}
      ]

      for {event, values} <- presses do
        Application.put_env(:patchbay, :moderator_wallets, listed)
        view = open(conn, moderator)
        Application.put_env(:patchbay, :moderator_wallets, [])

        assert {:error, {:redirect, %{to: "/"}}} = render_click(view, event, values),
               "#{event} #{inspect(values)}"
      end

      assert Ash.get!(Report, thread.id, authorize?: false).visibility == :published
      assert Ash.get!(Report, held.id, authorize?: false).visibility == :quarantined
      assert ruling(check) == nil
      assert Forum.get_post_check!(check.id, authorize?: false).lifted_at == nil

      assert ModerationAction |> Ash.read!(authorize?: false) |> Enum.map(& &1.action) == [
               :quarantine
             ]
    end

    test "a moderator signed out while the page is open decides nothing", %{conn: conn} do
      thread = thread!()
      moderator = moderator()
      view = open(conn, moderator)
      Identity.suspend_profile!(moderator, "Left the team", actor: %{role: :system})

      assert {:error, {:redirect, %{to: "/"}}} =
               render_click(view, "moderate", %{
                 "subject" => %{"kind" => "thread", "id" => thread.id, "action" => "quarantine"}
               })

      assert Ash.get!(Report, thread.id, authorize?: false).visibility == :published
      assert Ash.read!(ModerationAction, authorize?: false) == []
    end
  end

  # The moderation page as `profile` opens it, joined to its live part.
  defp open(conn, profile) do
    page = conn |> sign_in(profile.id) |> get(~p"/moderation")
    session = page |> html_response(200) |> LivePart.session(ModerationLive)
    {:ok, view, _html} = live_isolated(LivePart.browser(page), ModerationLive, session: session)
    view
  end

  # Another browser, holding `cookie`, joining the live part of the page the
  # moderator was sent: its first render is the page's own.
  defp joined_with(page, cookie) do
    build_conn()
    |> init_test_session(cookie)
    |> merge_assigns(current_profile: page.assigns.current_profile)
  end

  # A decision on a row's record, with the reason typed beside it.
  defp moderate(view, row, action, reason) do
    view
    |> form("#pb-mod-#{row}-decide", subject: %{reason: reason})
    |> put_submitter("button[value=#{action}]")
    |> render_submit()
  end

  defp review(view, check, action) do
    view
    |> element("#pb-mod-post-#{check.id} button[phx-value-action=#{action}]")
    |> render_click()
  end

  # Reads the test's own record back.
  defp ruling(check), do: Forum.get_post_check!(check.id, authorize?: false).ruling

  defp person!(name) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:moderation-#{name}",
      wallet_address: "0x" <> (:crypto.hash(:sha, name) |> Base.encode16(case: :lower))
    })
  end

  defp thread!(attrs \\ %{}) do
    {:ok, site} = Forum.register_site("shop.example")

    # Seeded by Patchbay itself, as nobody in particular.
    Forum.ask_question!(
      Map.merge(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "Does checkout handle declined cards?",
          thread_kind: :help_needed,
          body_markdown: "A declined card leaves the cart empty. Is that the site's doing?"
        },
        attrs
      ),
      authorize?: false
    )
  end

  # Seeded by Patchbay itself, as nobody in particular.
  defp reply!(thread) do
    Forum.add_reply!(
      %{
        report_id: thread.id,
        browser_session_id: Ash.UUID.generate(),
        verdict: :unknown,
        note: "Declined cards empty the cart on purpose."
      },
      authorize?: false
    )
  end

  # A post Jev turned away for `person`, as the posting check records it.
  defp turned_away!(person) do
    Ash.create!(
      PostCheck,
      %{
        profile_id: person.id,
        kind: :report,
        finding: :spam,
        confidence: 0.95,
        rejected: true,
        model: "jev-stand-in",
        input_sha256: String.duplicate("0", 64),
        shown: %{"title" => "Buy followers today", "body" => "Cheap followers here."}
      },
      action: :record,
      authorize?: false
    )
  end
end
