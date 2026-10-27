defmodule PatchbayWeb.TrailingSlashTest do
  # Adapted from ash-template 9dd2237: trailing_slash_test.exs. The router matched
  # /about/ as /about, so every page answered at a second address.
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Patchbay.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  test "a page address with a slash at the end is the site's not-found page" do
    for path <- ["/about/", "/contact/", "/wallet-bench/", "/llms.txt/"] do
      response = request(path, "text/html")
      assert response.status == 404
      assert response.resp_body =~ "There is nothing at this address."
    end
  end

  test "an API address with a slash at the end is the API's not-found answer" do
    response = request("/hello/", "*/*")
    assert response.status == 404
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "application/json"
    assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(response.resp_body)
  end

  test "the homepage keeps its slash" do
    assert request("/", "text/html").status == 200
  end

  defp request(path, accept) do
    :get
    |> conn(path)
    |> put_req_header("accept", accept)
    |> PatchbayWeb.Endpoint.call(PatchbayWeb.Endpoint.init([]))
  end
end
