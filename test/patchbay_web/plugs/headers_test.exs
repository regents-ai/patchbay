defmodule PatchbayWeb.Plugs.HeadersTest do
  use PatchbayWeb.ConnCase, async: true

  test "the room route sets the WebMCP permissions policy", %{conn: conn} do
    conn = get(conn, ~p"/webmcp/rooms/skill-uplift")

    assert get_resp_header(conn, "permissions-policy") == ["tools=(self)"]
  end

  test "the room route sets a content security policy with no unsafe-eval", %{conn: conn} do
    conn = get(conn, ~p"/webmcp/rooms/skill-uplift")

    assert [policy] = get_resp_header(conn, "content-security-policy")

    refute policy =~ "unsafe-eval"
    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "connect-src 'self' ws://www.example.com wss://www.example.com"
  end

  test "the landing redirect carries the same browser policy", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert conn.status == 302
    assert get_resp_header(conn, "permissions-policy") == ["tools=(self)"]
    assert [policy] = get_resp_header(conn, "content-security-policy")
    refute policy =~ "unsafe-eval"
  end

  test "the inline theme script carries the nonce named by the policy", %{conn: conn} do
    conn = get(conn, ~p"/webmcp/rooms/skill-uplift")

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy)
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end
end
