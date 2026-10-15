defmodule PatchbayWeb.ContentNegotiationTest do
  # Adapted from ash-template 574a5bf: content_negotiation_test.exs.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [assert_error_sent: 2]
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Patchbay.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  # Regression: allowing JSON on a LiveView route sends {:safe, html} to Jason
  # and crashes. Both ways of selecting that format must fail before rendering.
  test "HTML pages reject JSON selected by Accept or _format" do
    assert_error_sent(406, fn -> request("/account", "application/json") end)
    assert_error_sent(406, fn -> request("/account?_format=json", "text/html") end)
  end

  test "a browser or an Accept header with an HTML fallback still gets LiveView HTML" do
    for accept <- ["text/html", "application/json, text/html;q=0.9"] do
      response = request("/offers/how-it-works", accept)
      assert response.status == 200
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "text/html"
      assert response.resp_body =~ "data-phx-main"
    end
  end

  # JSON session requests keep their existing forgery protection and are not
  # mistaken for page requests. No sign-in or account write reaches a controller.
  test "the existing JSON session route still enforces CSRF" do
    assert_error_sent(403, fn ->
      :post
      |> conn("/auth/privy/session")
      |> put_req_header("accept", "application/json")
      |> PatchbayWeb.Endpoint.call(PatchbayWeb.Endpoint.init([]))
    end)
  end

  test "the existing negotiated Markdown document stays available" do
    response = request("/", "text/markdown")
    assert response.status == 200
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/markdown"
    refute response.resp_body =~ "data-phx-main"
  end

  defp request(path, accept) do
    :get
    |> conn(path)
    |> put_req_header("accept", accept)
    |> PatchbayWeb.Endpoint.call(PatchbayWeb.Endpoint.init([]))
  end
end
