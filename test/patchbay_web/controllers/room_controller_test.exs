defmodule PatchbayWeb.RoomControllerTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Fixtures, RoomEntrance}
  alias PatchbayWeb.Plugs.CurrentProfile

  setup do
    previous = Application.get_env(:patchbay, :max_rooms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:patchbay, :max_rooms)
      else
        Application.put_env(:patchbay, :max_rooms, previous)
      end
    end)

    :ok
  end

  test "the published demo address is a shared read-only preview", %{conn: conn} do
    html = conn |> get(~p"/webmcp/rooms/skill-uplift") |> html_response(200)

    assert Domain.get_room_by_slug!("skill-uplift").title == "Skill Uplift Studio"
    assert html =~ ~s(data-room-slug="skill-uplift")
    assert html =~ ~s(data-readonly="true")
    assert html =~ "This is a dev playground just for you and your agent"
    assert html =~ "This preview is read-only. Sign in to get a room of your own."
    refute html =~ "This is your room; nobody else is sent here"
    refute html =~ ~s(id="patchbay-reset")
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/sites")
    assert html =~ "Patchbay"
    assert html =~ "Reports"
  end

  test "two unsigned visitors share the preview rather than each getting a room", %{conn: conn} do
    first = conn |> get(~p"/webmcp/rooms/skill-uplift") |> html_response(200)
    second = build_conn() |> get(~p"/webmcp/rooms/skill-uplift") |> html_response(200)

    assert first =~ ~s(data-room-slug="skill-uplift")
    assert second =~ ~s(data-room-slug="skill-uplift")
    assert Domain.get_room_by_slug!("skill-uplift").seed_version == Fixtures.seed_version()
  end

  test "signing in creates one personal room and sends the visitor there", %{conn: conn} do
    profile = profile("room-one")
    slug = RoomEntrance.personal_slug(profile)

    conn = conn |> signed_in(profile) |> get(~p"/webmcp/rooms/skill-uplift")

    assert redirected_to(conn, 302) == "/webmcp/rooms/#{slug}"
    assert Domain.get_room_by_slug!(slug).title == "Skill Uplift Studio"

    html =
      conn
      |> recycle()
      |> signed_in(profile)
      |> get(~p"/webmcp/rooms/#{slug}")
      |> html_response(200)

    assert html =~ ~s(data-room-slug="#{slug}")
    assert html =~ ~s(data-readonly="false")
    assert html =~ "This is a dev playground just for you and your agent"
    refute html =~ "This preview is read-only"
    assert html =~ ~s(id="patchbay-reset")
    assert html =~ ~s(href="/")
  end

  test "a returning signed-in visitor lands back in the same personal room", %{conn: conn} do
    profile = profile("room-again")
    slug = RoomEntrance.personal_slug(profile)

    first = conn |> signed_in(profile) |> get(~p"/webmcp/rooms/skill-uplift")
    assert redirected_to(first, 302) == "/webmcp/rooms/#{slug}"

    second =
      build_conn()
      |> signed_in(profile)
      |> get(~p"/webmcp/rooms/skill-uplift")

    assert redirected_to(second, 302) == "/webmcp/rooms/#{slug}"
  end

  test "two signed-in profiles get different rooms", %{conn: conn} do
    one = profile("room-a")
    two = profile("room-b")

    slug_one =
      conn |> signed_in(one) |> get(~p"/webmcp/rooms/skill-uplift") |> redirected_room_slug()

    slug_two =
      build_conn()
      |> signed_in(two)
      |> get(~p"/webmcp/rooms/skill-uplift")
      |> redirected_room_slug()

    refute slug_one == slug_two
    assert slug_one == RoomEntrance.personal_slug(one)
    assert slug_two == RoomEntrance.personal_slug(two)
  end

  test "an unknown room slug is not found", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/webmcp/rooms/no-such-room") end
  end

  test "a full deployment asks a first visitor to come back later", %{conn: conn} do
    Domain.create_seeded_room!("occupied-room")
    Application.put_env(:patchbay, :max_rooms, 1)

    conn = get(conn, ~p"/webmcp/rooms/skill-uplift")

    assert redirected_to(conn, 302) == "/webmcp/rooms/busy"
    follow = get(recycle(conn), ~p"/webmcp/rooms/busy")
    assert follow.status == 503
    assert html_response(follow, 503) =~ "Patchbay is busy, try again in a few minutes."
    assert html_response(follow, 503) =~ ~s(href="/")
  end

  test "the come-back-later page names itself in the browser tab", %{conn: conn} do
    Domain.create_seeded_room!("occupied-room")
    Application.put_env(:patchbay, :max_rooms, 1)

    html =
      conn
      |> get(~p"/webmcp/rooms/skill-uplift")
      |> recycle()
      |> get(~p"/webmcp/rooms/busy")
      |> html_response(503)

    assert html =~ ~r{<title[^>]*>\s*All rooms are busy\s*· Patchbay</title>}
  end

  defp profile(subject) do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> subject,
      wallet_address:
        "0x" <>
          (subject
           |> :erlang.md5()
           |> Base.encode16(case: :lower)
           |> String.pad_trailing(40, "0"))
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentProfile.session_key(), profile.id)
  end

  defp redirected_room_slug(conn) do
    "/webmcp/rooms/" <> slug = redirected_to(conn, 302)
    slug
  end
end
