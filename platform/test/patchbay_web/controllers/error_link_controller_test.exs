defmodule PatchbayWeb.ErrorLinkControllerTest do
  @moduledoc """
  The lasting link the Regents command line prints beside each of its own
  errors leads to the post about that error, and a code with no post offers a
  search instead.
  """

  use PatchbayWeb.ConnCase, async: false

  alias PatchbayWeb.ErrorLinkController
  alias PatchbayWeb.ErrorReports
  alias PatchbayWeb.Forum.PostAddress

  @codes ~w(not_signed_in agent_not_paired person_not_here no_touch_id
            key_helper_not_answering locked_key_needs_mac code_sign_in)

  test "every code the command line prints has a post" do
    assert @codes |> Enum.sort() == ErrorLinkController.links() |> Map.keys() |> Enum.sort()

    for {_code, id} <- ErrorLinkController.links(), do: assert({:ok, _} = Ecto.UUID.cast(id))
  end

  test "a code leads for good to its post's own address", %{conn: conn} do
    site = ErrorReports.site!("keyfleet.example")
    id = ErrorLinkController.links()["not_signed_in"]
    post = ErrorReports.post!(site, ErrorReports.get!("keyfleet_join"), id)

    for code <- ~w(not_signed_in agent_not_paired person_not_here) do
      moved = get(conn, "/errors/" <> code)
      assert redirected_to(moved, 301) == PostAddress.path(post)
    end

    assert conn |> get(PostAddress.path(post)) |> html_response(200) =~ "not_signed_in"
  end

  test "a code with no post, or whose post is gone, offers a search", %{conn: conn} do
    for code <- ["no_such_error", "no_touch_id"] do
      html = conn |> get("/errors/" <> code) |> html_response(404)

      assert html =~ "No help for that error yet"
      assert html =~ ~s(href="/?q=#{code}")
    end

    md =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/errors/no_such_error")
      |> response(404)

    assert md =~ "(/?q=no_such_error)"
  end
end
