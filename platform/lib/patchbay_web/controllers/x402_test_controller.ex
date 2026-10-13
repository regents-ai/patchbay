defmodule PatchbayWeb.X402TestController do
  @moduledoc """
  The Wallet Bench's paid-call test page. `PatchbayWeb.Plugs.X402Test` stands
  in front of it, so this answer is reached only by a request that paid, and
  is sent only once that payment has settled.
  """

  use PatchbayWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{message: "test passed"})
  end
end
