defmodule PatchbayWeb.SharedProfileController do
  use PatchbayWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:show, page_title: "Profile")
  end
end
