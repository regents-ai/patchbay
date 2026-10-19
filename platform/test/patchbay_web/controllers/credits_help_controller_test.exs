defmodule PatchbayWeb.CreditsHelpControllerTest do
  @moduledoc """
  Credits help never breaks on an old link or an odd form: a page cursor that
  no longer reads starts again from the newest post, and a form that arrives in
  the wrong shape is shown again with what's missing.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Identity
  alias PatchbayWeb.Plugs.CurrentProfile

  setup %{conn: conn} do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: "did:privy:credits-help",
        wallet_address: "0x" <> String.duplicate("d", 40)
      })

    signed_in =
      conn
      |> Plug.Test.init_test_session(%{})
      |> CurrentProfile.sign_in(person.id)

    %{signed_in: signed_in}
  end

  test "a page cursor that no longer reads starts from the newest posts", %{signed_in: conn} do
    html = conn |> get(~p"/credits-help?after=not-a-cursor") |> html_response(200)
    assert html =~ "Credits help"
  end

  test "a post whose form arrived in the wrong shape is shown again with its problem", %{
    signed_in: conn
  } do
    for params <- [%{"post" => "x"}, %{}] do
      html = conn |> post(~p"/credits-help", params) |> html_response(200)
      assert html =~ "Give it a title of up to 140 characters"
    end
  end
end
