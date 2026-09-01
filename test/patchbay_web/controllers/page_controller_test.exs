defmodule PatchbayWeb.PageControllerTest do
  use PatchbayWeb.ConnCase

  test "GET / sends visitors to the public room", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn, 302) == ~p"/webmcp/rooms/skill-uplift"
  end
end
