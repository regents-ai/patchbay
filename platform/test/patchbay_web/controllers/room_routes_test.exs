defmodule PatchbayWeb.RoomRoutesTest do
  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

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
    |> CurrentProfile.sign_in(profile.id)
  end
end
