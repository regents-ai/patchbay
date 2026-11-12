defmodule PatchbayWeb.PersonAdminLiveTest do
  @moduledoc """
  A person's admin page (PB-88): a moderator suspends and reinstates from the
  web through the same two actions Patchbay's console runs, and reads the
  record of both, each with the moderator who made it, or "Console". The
  record names the acting moderator and nobody a caller chooses, and is written
  only by the two actions. Anyone else is answered as though the page does not exist,
  and the actions refuse them whatever page they came from. A moderator never
  changes their own status, so a suspended one cannot reinstate themself.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false
  use Oban.Testing, repo: Patchbay.Repo

  import Patchbay.OffersFixtures, only: [moderator: 0]
  import Phoenix.LiveViewTest

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Identity.DisconnectApps
  alias Patchbay.Identity.StatusChange
  alias PatchbayWeb.Plugs.CurrentProfile

  @console %{role: :system}

  describe "the page" do
    test "is not there for a visitor, a signed-in person, or a moderator asking for nobody",
         %{conn: conn} do
      person = person!()
      path = "/admin/people/#{person.public_id}"

      assert_error_sent(404, fn -> get(conn, path) end)
      assert_error_sent(404, fn -> conn |> signed_in(person!()) |> get(path) end)
      assert_error_sent(404, fn -> conn |> signed_in(person) |> get(path) end)

      assert_error_sent(404, fn ->
        conn |> signed_in(moderator()) |> get("/admin/people/agt_nobody")
      end)

      assert Identity.get_profile!(person.id).status == :active
    end

    test "suspends for a reason, ending the person's sign-ins, then reinstates, showing each as it happens",
         %{conn: conn} do
      person = person!()
      theirs = signed_in(conn, person)
      assert theirs |> get("/account") |> html_response(200) =~ "pb-account"
      {:ok, their_page, _html} = live(theirs, "/account")
      refute has_element?(their_page, "#account-signed-out")
      moderator = moderator()

      {:ok, view, _html} =
        conn |> signed_in(moderator) |> live("/admin/people/#{person.public_id}")

      assert has_element?(view, "#pb-person-status[data-status=active]")
      refute has_element?(view, "#pb-person-history li")

      view |> form("#pb-person-suspend", %{"reason" => "Spam"}) |> render_submit()

      assert has_element?(view, "#pb-person-status[data-status=suspended]")
      assert has_element?(view, "#pb-person-history li", "Spam")
      assert has_element?(view, "#pb-person-history li", AgentProfile.own_name(moderator))
      refute has_element?(view, "#pb-person-suspend")

      # What PB-80 defines: the profile is suspended, its apps job is queued,
      # and every sign-in it held reads as signed out, an open page at its
      # next step.
      assert %{status: :suspended, sessions_valid_after: %DateTime{}} =
               Identity.get_profile!(person.id)

      assert_enqueued(worker: DisconnectApps, args: %{profile_id: person.id})
      assert CurrentProfile.signed_in_profile(get_session(theirs)) == nil
      send(their_page.pid, :agents_changed)
      assert has_element?(their_page, "#account-signed-out")

      view |> form("#pb-person-reinstate", %{"reason" => "Appeal upheld"}) |> render_submit()

      assert has_element?(view, "#pb-person-status[data-status=active]")
      assert has_element?(view, "#pb-person-suspend")
      assert Identity.get_profile!(person.id).status == :active
      assert CurrentProfile.signed_in_profile(get_session(theirs)) == nil

      moderator_id = moderator.id

      assert [
               %{action: :suspend, reason: "Spam", moderator_id: ^moderator_id},
               %{action: :reinstate, reason: "Appeal upheld", moderator_id: ^moderator_id}
             ] = Identity.status_changes!(person.id, actor: @console)
    end

    test "says Console for a change made at the console, beside a moderator's own",
         %{conn: conn} do
      moderator = moderator()
      person = person!()
      Identity.suspend_profile!(person, "Spam", actor: @console)

      {:ok, view, _html} =
        conn |> signed_in(moderator) |> live("/admin/people/#{person.public_id}")

      assert [%{id: by_console, moderator_id: nil}] =
               Identity.status_changes!(person.id, actor: @console)

      assert has_element?(view, "#pb-person-change-#{by_console}", "Console")

      view |> form("#pb-person-reinstate", %{"reason" => "Appeal upheld"}) |> render_submit()

      assert [_console, %{id: by_moderator, moderator_id: moderator_id}] =
               Identity.status_changes!(person.id, actor: @console)

      assert moderator_id == moderator.id
      assert has_element?(view, "#pb-person-change-#{by_console}", "Console")
      refute has_element?(view, "#pb-person-change-#{by_moderator}", "Console")

      assert has_element?(
               view,
               "#pb-person-change-#{by_moderator} a[href='#{AgentProfile.profile_url(moderator)}']"
             )
    end

    test "changes nothing without a reason", %{conn: conn} do
      person = person!()

      {:ok, view, _html} =
        conn |> signed_in(moderator()) |> live("/admin/people/#{person.public_id}")

      view |> form("#pb-person-suspend", %{"reason" => ""}) |> render_submit()

      assert has_element?(view, "#pb-person-problem")
      assert has_element?(view, "#pb-person-status[data-status=active]")
      assert Identity.get_profile!(person.id).status == :active
      assert Identity.status_changes!(person.id, actor: @console) == []
    end

    test "offers a moderator no action on themself, and refuses the press all the same",
         %{conn: conn} do
      moderator = moderator()

      {:ok, view, _html} =
        conn |> signed_in(moderator) |> live("/admin/people/#{moderator.public_id}")

      refute has_element?(view, "#pb-person-suspend")
      render_submit(view, "suspend", %{"reason" => "Oops"})

      assert has_element?(view, "#pb-person-problem")
      assert Identity.get_profile!(moderator.id).status == :active
    end

    test "ends for a moderator who is suspended while it is open", %{conn: conn} do
      moderator = moderator()
      person = person!()

      {:ok, view, _html} =
        conn |> signed_in(moderator) |> live("/admin/people/#{person.public_id}")

      Identity.suspend_profile!(moderator, "Left the team", actor: @console)

      assert {:error, {:redirect, %{to: "/"}}} =
               view |> form("#pb-person-suspend", %{"reason" => "Spam"}) |> render_submit()

      assert Identity.get_profile!(person.id).status == :active
    end
  end

  describe "the actions" do
    test "admit an active moderator acting on someone else, and nobody else" do
      moderator = moderator()
      person = person!()

      refused = [
        nil,
        person,
        person!(),
        Patchbay.AssistFixtures.paired_agent(),
        # A wallet signing as itself is not a web sign-in, whatever its address.
        Identity.upsert_from_wallet!(%{wallet_address: moderator.wallet_address})
      ]

      for actor <- refused do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Identity.suspend_profile(person, "Spam", actor: actor)

        refute match?({:ok, [_ | _]}, Identity.status_changes(person.id, actor: actor))
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.suspend_profile(moderator, "Oops", actor: moderator)

      assert Identity.get_profile!(person.id).status == :active
      assert Identity.status_changes!(person.id, actor: @console) == []
      refute_enqueued(worker: DisconnectApps)

      assert {:ok, suspended} = Identity.suspend_profile(person, "Spam", actor: moderator)
      assert [%{action: :suspend}] = Identity.status_changes!(person.id, actor: moderator)

      for actor <- refused do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Identity.reinstate_profile(suspended, "Appeal upheld", actor: actor)
      end

      assert Identity.get_profile!(person.id).status == :suspended
    end

    test "name the acting moderator, never one the caller sends" do
      moderator = moderator()
      other = moderator()
      person = person!()

      assert {:error, %Ash.Error.Invalid{}} =
               Identity.suspend_profile(person, "Spam", %{moderator_id: other.id},
                 actor: moderator
               )

      assert Identity.get_profile!(person.id).status == :active
      assert Identity.status_changes!(person.id, actor: @console) == []

      suspended = Identity.suspend_profile!(person, "Spam", actor: moderator)

      assert {:error, %Ash.Error.Invalid{}} =
               Identity.reinstate_profile(suspended, "Appeal upheld", %{moderator_id: other.id},
                 actor: moderator
               )

      Identity.reinstate_profile!(suspended, "Appeal upheld", actor: other)

      assert Enum.map(Identity.status_changes!(person.id, actor: @console), & &1.moderator_id) ==
               [moderator.id, other.id]
    end

    test "alone write the record: a row asked for on its own is refused, whoever asks" do
      moderator = moderator()
      person = person!()
      row = %{profile_id: person.id, action: :suspend, reason: "Spam"}

      refused? = fn actor ->
        match?(
          {:error, %Ash.Error.Forbidden{}},
          StatusChange |> Ash.Changeset.for_create(:record, row, actor: actor) |> Ash.create()
        )
      end

      assert Enum.all?([moderator, @console, person, nil], refused?)

      # Nor can a row be asked to name a moderator.
      assert {:error, %Ash.Error.Invalid{}} =
               StatusChange
               |> Ash.Changeset.for_create(:record, Map.put(row, :moderator_id, moderator.id),
                 actor: moderator
               )
               |> Ash.create()

      refute function_exported?(Identity, :record_status_change, 2)
      assert Identity.status_changes!(person.id, actor: @console) == []
    end

    test "refuse a suspended moderator, on themself and on anyone else" do
      moderator = moderator()
      person = person!()
      suspended = Identity.suspend_profile!(moderator, "Left the team", actor: @console)

      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.reinstate_profile(suspended, "Back", actor: suspended)

      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.suspend_profile(person, "Spam", actor: suspended)

      refute match?({:ok, [_ | _]}, Identity.status_changes(moderator.id, actor: suspended))
      assert Identity.get_profile!(moderator.id).status == :suspended
      assert Identity.get_profile!(person.id).status == :active

      # Another moderator reinstates them.
      assert {:ok, %{status: :active}} =
               Identity.reinstate_profile(suspended, "Back", actor: moderator())
    end
  end

  defp person! do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:person-admin-#{System.unique_integer([:positive])}",
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id, System.os_time(:second) - 5)
  end
end
