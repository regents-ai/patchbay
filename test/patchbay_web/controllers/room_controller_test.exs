defmodule PatchbayWeb.RoomControllerTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.Fixtures

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

  test "GET / sends a first-time visitor into a room of their own", %{conn: conn} do
    conn = get(conn, ~p"/")

    slug = redirected_room_slug(conn)

    refute slug == "skill-uplift"
    assert byte_size(slug) >= 16

    room = Domain.get_room_by_slug!(slug)
    assert room.title == "Skill Uplift Studio"
    assert room.desired_tool_generation == 1
    assert room.seed_version == Fixtures.seed_version()
  end

  test "a new room already offers its generation-1 tool", %{conn: conn} do
    room = Domain.get_room_by_slug!(redirected_room_slug(get(conn, ~p"/")))

    assert [revision] =
             Domain.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired]])

    assert revision.generation == 1
    assert revision.name == "uplift_current_skill_v1"
  end

  test "GET /webmcp/rooms/skill-uplift sends the visitor to their own room too", %{conn: conn} do
    conn = get(conn, ~p"/webmcp/rooms/skill-uplift")

    refute redirected_room_slug(conn) == "skill-uplift"
  end

  test "two visitors get different rooms with identical seeded state", %{conn: conn} do
    first = Domain.get_room_by_slug!(redirected_room_slug(get(conn, ~p"/")))
    second = Domain.get_room_by_slug!(redirected_room_slug(get(build_conn(), ~p"/")))

    refute first.slug == second.slug
    refute first.id == second.id

    seeded = [
      :title,
      :goal_kind,
      :goal_text,
      :source_markdown,
      :source_sha256,
      :candidate_markdown,
      :ui_revision,
      :desired_tool_generation,
      :seed_version,
      :status
    ]

    assert Map.take(first, seeded) == Map.take(second, seeded)
  end

  test "a returning visitor lands back in the same room", %{conn: conn} do
    conn = get(conn, ~p"/")
    slug = redirected_room_slug(conn)

    conn = conn |> recycle() |> get(~p"/webmcp/rooms/skill-uplift")

    assert redirected_room_slug(conn) == slug
  end

  test "opening somebody else's room does not change which room is yours", %{conn: conn} do
    conn = get(conn, ~p"/")
    own_slug = redirected_room_slug(conn)

    other = Domain.create_seeded_room!("someone-else")

    conn = conn |> recycle() |> get(~p"/webmcp/rooms/#{other.slug}")
    assert conn.status == 200

    conn = conn |> recycle() |> get(~p"/")
    assert redirected_room_slug(conn) == own_slug
  end

  test "a remembered room that no longer exists gives the visitor a fresh one", %{conn: conn} do
    conn = get(conn, ~p"/")
    slug = redirected_room_slug(conn)

    Domain.get_room_by_slug!(slug) |> Domain.discard_room!()

    conn = conn |> recycle() |> get(~p"/")

    refute redirected_room_slug(conn) == slug
  end

  test "an unknown room slug is not found", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/webmcp/rooms/no-such-room") end
  end

  test "a full deployment asks the visitor to come back later", %{conn: conn} do
    Domain.create_seeded_room!("occupied-room")
    Application.put_env(:patchbay, :max_rooms, 1)

    conn = get(conn, ~p"/")

    assert conn.status == 503
    assert html_response(conn, 503) =~ "Patchbay is busy, try again in a few minutes."
  end

  test "the come-back-later page names itself in the browser tab", %{conn: conn} do
    Domain.create_seeded_room!("occupied-room")
    Application.put_env(:patchbay, :max_rooms, 1)

    conn = get(conn, ~p"/")

    assert html_response(conn, 503) =~ ~r{<title[^>]*>\s*All rooms are busy\s*· Patchbay</title>}
  end

  defp redirected_room_slug(conn) do
    "/webmcp/rooms/" <> slug = redirected_to(conn, 302)
    slug
  end
end
