defmodule PatchbayWeb.Plugs.HeadersTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Patchbay, as: Domain

  setup do
    room = Domain.create_seeded_room!("headers-#{System.unique_integer([:positive])}")
    %{room: room}
  end

  test "the room route sets the WebMCP permissions policy", %{conn: conn, room: room} do
    conn = get(conn, ~p"/webmcp/rooms/#{room.slug}")

    assert get_resp_header(conn, "permissions-policy") == ["tools=(self)"]
  end

  test "the room route sets a content security policy with no unsafe-eval", %{
    conn: conn,
    room: room
  } do
    conn = get(conn, ~p"/webmcp/rooms/#{room.slug}")

    assert [policy] = get_resp_header(conn, "content-security-policy")

    refute policy =~ "unsafe-eval"
    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "connect-src 'self' ws://www.example.com wss://www.example.com"
  end

  test "the front door carries the same browser policy", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert conn.status == 200
    assert get_resp_header(conn, "permissions-policy") == ["tools=(self)"]
    assert [policy] = get_resp_header(conn, "content-security-policy")
    refute policy =~ "unsafe-eval"
  end
end
