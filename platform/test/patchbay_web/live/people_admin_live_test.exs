defmodule PatchbayWeb.PeopleAdminLiveTest do
  @moduledoc """
  The people list (`/admin/people`): a moderator finds a person, newest first,
  a page at a time, narrowed by a name or by the start of a wallet address or
  public id, or to the suspended alone, and opens their admin page from the
  row. Anyone else is answered as though the page does not exist, at both
  addresses, and the list refuses them at the action whatever page they came
  from.

  The moderator list is application-wide, so this file runs alone.
  """

  use PatchbayWeb.ConnCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import Phoenix.LiveViewTest

  alias Patchbay.Identity

  @console %{role: :system}

  describe "the door" do
    test "is not there for a visitor or a signed-in person", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, "/admin/people") end)
      assert_error_sent(404, fn -> conn |> signed_in(person!()) |> get("/admin/people") end)
    end

    test "is not there at the open address, even for a moderator", %{conn: conn} do
      assert_error_sent(404, fn ->
        conn |> signed_in(moderator()) |> on_open() |> get("/admin/people")
      end)
    end

    test "the list refuses anyone but a moderator at the action" do
      person = person!()

      assert {:error, %Ash.Error.Forbidden{}} = Identity.list_people(%{}, actor: person)
      assert {:error, %Ash.Error.Forbidden{}} = Identity.list_people(%{}, actor: nil)
      assert {:error, %Ash.Error.Forbidden{}} = Identity.list_people(%{}, actor: @console)

      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.list_people(%{search: person.public_id}, actor: person)

      assert {:ok, %{results: [_ | _]}} = Identity.list_people(%{}, actor: moderator())
    end
  end

  describe "the list" do
    test "shows everyone newest first, each row opening that person's page", %{conn: conn} do
      [first, second, third] = for _n <- 1..3, do: person!()
      moderator = moderator()

      {:ok, view, html} = conn |> signed_in(moderator) |> live("/admin/people")

      assert ids(html) == Enum.map([moderator, third, second, first], & &1.public_id)
      assert has_element?(view, "#pb-person-#{first.public_id} [data-status=active]")
      assert has_element?(view, "#pb-person-#{first.public_id} time")
      refute has_element?(view, "#pb-people-older")

      view
      |> element("#pb-person-#{second.public_id} a")
      |> render_click()
      |> follow_redirect(signed_in(conn, moderator), "/admin/people/#{second.public_id}")
    end

    test "pages older people, keeping the search", %{conn: conn} do
      people = for _n <- 1..52, do: person!()
      moderator = moderator()

      {:ok, view, html} = conn |> signed_in(moderator) |> live("/admin/people?q=agent-")

      # Every new profile's agent starts as "agent-" and part of its id, the
      # moderator's included.
      newest_first = Enum.map([moderator | Enum.reverse(people)], & &1.public_id)
      assert ids(html) == Enum.take(newest_first, 50)

      view |> element("#pb-people-older") |> render_click()

      assert view |> render() |> ids() == Enum.drop(newest_first, 50)
      refute has_element?(view, "#pb-people-older")
      assert has_element?(view, "#pb-people-search[value='agent-']")
    end

    test "says when nobody matches", %{conn: conn} do
      {:ok, view, _html} =
        conn |> signed_in(moderator()) |> live("/admin/people?q=nobody-by-this-name")

      refute has_element?(view, "#pb-people")
      assert has_element?(view, "#pb-people-admin .rg-empty")
    end
  end

  describe "the search" do
    setup %{conn: conn} do
      person = person!()
      named = Identity.rename_agent!(person, %{agent_name: "marigold-bot"}, actor: person)
      other = person!()
      moderator = moderator()
      {:ok, view, _html} = conn |> signed_in(moderator) |> live("/admin/people")
      %{view: view, named: named, other: other, moderator: moderator}
    end

    test "finds a person by part of a name, whatever its letter case", context do
      assert search(context.view, "RIGOLD") == [context.named.public_id]
    end

    test "finds a person by the start of a wallet address, and not by its middle", context do
      %{view: view, other: other} = context

      assert search(view, String.slice(other.wallet_address, 0, 12)) == [other.public_id]
      assert search(view, String.upcase(String.slice(other.wallet_address, 2, 10))) == []
      assert search(view, String.slice(other.wallet_address, 8, 12)) == []
    end

    test "finds a person by the start of a public id", context do
      %{view: view, other: other} = context

      assert search(view, String.slice(other.public_id, 0, 14)) == [other.public_id]
      assert search(view, String.slice(other.public_id, 6, 14)) == []
    end

    test "runs when the box is left as well as on Enter, and an empty box shows everyone",
         context do
      %{view: view, named: named, other: other, moderator: moderator} = context

      html = view |> form("#pb-people-filter") |> render_change(%{"q" => "marigold"})
      assert ids(html) == [named.public_id]
      assert_patch(view, "/admin/people?q=marigold")

      assert search(view, "") == Enum.map([moderator, other, named], & &1.public_id)
      assert_patch(view, "/admin/people")
    end

    test "takes any text as text", context do
      assert search(context.view, "%") == []
      assert search(context.view, "_") == []
      assert search(context.view, "' OR 1=1 --") == []
    end
  end

  describe "the suspended filter" do
    test "keeps only suspended people, alone or with a search", %{conn: conn} do
      [active, suspended, also_suspended] = for _n <- 1..3, do: person!()
      Identity.suspend_profile!(suspended, "Spam", actor: @console)
      Identity.suspend_profile!(also_suspended, "Spam", actor: @console)

      {:ok, view, _html} = conn |> signed_in(moderator()) |> live("/admin/people")

      html = view |> form("#pb-people-filter") |> render_change(%{"suspended" => "true"})
      assert ids(html) == [also_suspended.public_id, suspended.public_id]
      assert_patch(view, "/admin/people?suspended=true")
      assert has_element?(view, "#pb-person-#{suspended.public_id} [data-status=suspended]")

      html =
        view
        |> form("#pb-people-filter")
        |> render_change(%{
          "q" => String.slice(suspended.public_id, 0, 14),
          "suspended" => "true"
        })

      assert ids(html) == [suspended.public_id]

      html =
        view
        |> form("#pb-people-filter")
        |> render_change(%{"q" => String.slice(active.public_id, 0, 14), "suspended" => "true"})

      assert ids(html) == []
    end
  end

  defp search(view, text) do
    view |> form("#pb-people-filter") |> render_submit(%{"q" => text}) |> ids()
  end

  # The public ids of the rows showing, in the order they show.
  defp ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#pb-people > li")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "pb-person-", ""))
  end

  defp person! do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:people-admin-#{System.unique_integer([:positive])}",
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> recycle()
    |> sign_in(profile.id, DateTime.add(DateTime.utc_now(), -5))
  end
end
