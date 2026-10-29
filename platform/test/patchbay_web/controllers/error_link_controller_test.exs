defmodule PatchbayWeb.ErrorLinkControllerTest do
  @moduledoc """
  The lasting link the Regents command line prints beside each of its own
  errors leads to the post about that error, and a code with no post offers a
  search instead.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum.PostAddress
  alias PatchbayWeb.ErrorLinkController
  alias PatchbayWeb.ErrorReports

  @codes ~w(not_signed_in agent_not_paired person_not_here no_touch_id
            key_helper_not_answering locked_key_needs_mac code_sign_in)

  test "every code the command line prints has a post" do
    assert @codes |> Enum.sort() == ErrorLinkController.links() |> Map.keys() |> Enum.sort()

    for {_code, id} <- ErrorLinkController.links(), do: assert({:ok, _} = Ecto.UUID.cast(id))
  end

  test "a code leads for good to its post's own address", %{conn: conn} do
    site = ErrorReports.site!("keyfleet.example")
    report = ErrorReports.get!("keyfleet_join")

    for code <- ~w(not_signed_in agent_not_paired person_not_here) do
      post = ErrorReports.post!(site, report, ErrorLinkController.links()[code])
      moved = get(conn, "/errors/" <> code)
      assert redirected_to(moved, 301) == PostAddress.path(post)
      assert conn |> get(PostAddress.path(post)) |> html_response(200) =~ code
    end
  end

  test "a code with no post, or whose post is gone, offers a search", %{conn: conn} do
    for code <- ["no_such_error", "no_touch_id"] do
      html = conn |> get("/errors/" <> code) |> html_response(404)

      assert html =~ "Unknown error"
      assert html =~ ~s(href="/?q=#{code}")
    end

    md =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/errors/no_such_error")
      |> response(404)

    assert md =~ "Patchbay has no post about `no_such_error` yet."
    assert md =~ "at `#{PatchbayWeb.Endpoint.url()}/?q=no_such_error`,"
    refute md =~ "](/?q="
  end

  test "anything that cannot be a code is the ordinary missing page, which repeats none of it",
       %{conn: conn} do
    for code <- [
          "x`](https://evil.example)`",
          "[click](https://evil.example)",
          "<b>NOT_SIGNED_IN</b>",
          "Not_Signed_In",
          String.duplicate("a", 65)
        ] do
      path = "/errors/" <> URI.encode(code, &URI.char_unreserved?/1)

      assert_error_sent(404, fn -> get(conn, path) end)

      {404, _headers, md} =
        assert_error_sent(404, fn ->
          conn |> put_req_header("accept", "text/markdown") |> get(path)
        end)

      refute md =~ "evil.example"
      refute md =~ "click"
      refute md =~ code
    end
  end
end
