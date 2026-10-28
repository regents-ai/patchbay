defmodule PatchbayWeb.CreditsHelpControllerTest do
  @moduledoc """
  Credits help never breaks on an old link or an odd form: a page cursor that
  no longer reads starts again from the newest post, and a form that arrives in
  the wrong shape is shown again with what's missing. One person posts at most
  ten times an hour.
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

    %{signed_in: signed_in, person: person}
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

  describe "posting allowance" do
    defp ask(conn, title),
      do: post(conn, ~p"/credits-help", %{"post" => %{"title" => title, "body" => "My Credits."}})

    defp posts_by(profile_id) do
      require Ash.Query

      # Counted as the server sees the table, not as the author reads it.
      Patchbay.CreditsHelp.Post
      |> Ash.Query.filter(author_profile_id == ^profile_id)
      |> Ash.read!(authorize?: false)
      |> length()
    end

    test "ten posts an hour, then the person is told to wait and nothing is saved", %{
      signed_in: conn,
      person: person
    } do
      for n <- 1..10, do: assert(redirected_to(ask(conn, "Question #{n}")) =~ "/credits-help/")

      html = conn |> ask("One more") |> html_response(200)
      assert html =~ "You&#39;ve sent a lot of Credits help posts this hour. Try again later."
      assert posts_by(person.id) == 10
    end

    test "a post that does not save spends nothing, and one person's posts leave another's alone",
         %{conn: conn, signed_in: signed_in} do
      too_long = String.duplicate("x", 141)

      for _ <- 1..12,
          do: assert(html_response(ask(signed_in, too_long), 200) =~ "Give it a title")

      for n <- 1..10,
          do: assert(redirected_to(ask(signed_in, "Question #{n}")) =~ "/credits-help/")

      other =
        Identity.upsert_from_privy!(%{
          privy_user_id: "did:privy:credits-help-other",
          wallet_address: "0x" <> String.duplicate("e", 40)
        })

      other_conn = conn |> Plug.Test.init_test_session(%{}) |> CurrentProfile.sign_in(other.id)
      assert redirected_to(ask(other_conn, "Mine")) =~ "/credits-help/"
    end
  end
end
