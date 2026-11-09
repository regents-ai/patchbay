defmodule PatchbayWeb.PrivateDoorsTest do
  # Doors that must never open to the wrong person: the saved errors and the
  # answer check download answer only the site's admins. An agent's own
  # account reads are checked in PatchbayWeb.Security.AuthorizationCheckTest.
  #
  # The admin list is application-wide, so this file runs alone.
  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.Plugs.CurrentProfile
  alias PatchbayWeb.SignedAgent

  test "the saved errors and the answer check are not found for anyone but an admin",
       %{conn: conn} do
    admin = SignedAgent.pair!().owner
    visitor = SignedAgent.pair!().owner

    admins = Application.fetch_env!(:patchbay, :admins)
    Application.put_env(:patchbay, :admins, [admin.privy_user_id])
    on_exit(fn -> Application.put_env(:patchbay, :admins, admins) end)

    for path <- ["/admin/errors", "/admin/ai-answers.csv"] do
      assert conn |> get(path) |> html_response(404)
      assert conn |> signed_in(visitor) |> get(path) |> html_response(404)
    end

    assert conn |> signed_in(admin) |> get("/admin/errors") |> html_response(200)

    download = conn |> signed_in(admin) |> get("/admin/ai-answers.csv")
    assert response_content_type(download, :csv)
    assert response(download, 200) =~ ~s("week","engine","persona")
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> CurrentProfile.sign_in(profile.id, System.os_time(:second))
  end
end
