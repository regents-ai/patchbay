defmodule PatchbayWeb.AccountController do
  use PatchbayWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:show, page_title: "Account")
  end
end
