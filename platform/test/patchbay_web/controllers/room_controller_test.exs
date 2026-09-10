defmodule PatchbayWeb.RoomControllerTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias Patchbay.Patchbay, as: Domain

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

  test "the retired demo sends unsigned visitors to Agent Start", %{conn: conn} do
    assert conn |> get(~p"/webmcp/rooms/skill-uplift") |> redirected_to(302) == "/start"
  end

  test "the retired demo sends signed-in visitors to Agent Start", %{conn: conn} do
    conn = conn |> signed_in(profile("room-one")) |> get(~p"/webmcp/rooms/skill-uplift")
    assert redirected_to(conn, 302) == "/start"
  end

  test "an unknown room slug is not found", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/webmcp/rooms/no-such-room") end
  end

  test "the existing busy page remains available", %{conn: conn} do
    Domain.create_seeded_room!("occupied-room")
    Application.put_env(:patchbay, :max_rooms, 1)

    follow = get(conn, ~p"/webmcp/rooms/busy")
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
end
