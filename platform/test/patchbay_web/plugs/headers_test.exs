defmodule PatchbayWeb.Plugs.HeadersTest do
  use PatchbayWeb.ConnCase, async: true

  alias Patchbay.Patchbay, as: Domain

  setup do
    room = Domain.create_seeded_room!("headers-#{System.unique_integer([:positive])}")
    %{room: room}
  end

  # An SVG opened directly runs as a page, so a static file says it may do nothing.
  test "a static image is served with the policy that lets it do nothing", %{conn: conn} do
    conn = get(conn, "/favicon.svg")

    assert conn.status == 200

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
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
    assert policy =~ "default-src 'none'"

    assert policy =~
             "script-src 'self' https://challenges.cloudflare.com https://js.stripe.com https://*.js.stripe.com;"

    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "connect-src 'self' https://auth.privy.io"
    assert policy =~ "https://explorer-api.walletconnect.com"
    assert policy =~ "https://www.google.com"
    assert policy =~ "https://*.gstatic.com"
    assert policy =~ "wss://relay.walletconnect.com"
    assert policy =~ "frame-src https://auth.privy.io"
  end

  test "the front door carries the same browser policy", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert conn.status == 200
    assert get_resp_header(conn, "permissions-policy") == ["tools=(self)"]
    assert [policy] = get_resp_header(conn, "content-security-policy")
    refute policy =~ "unsafe-eval"
  end
end
