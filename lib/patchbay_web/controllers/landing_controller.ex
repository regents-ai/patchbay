defmodule PatchbayWeb.LandingController do
  use PatchbayWeb, :controller

  # The front door. It never opens a room by itself: a room is created only
  # when somebody follows the entrance link, so a crawler or a link preview
  # never costs the deployment one of its rooms.
  def show(conn, _params) do
    conn
    |> assign(:page_title, "A site that repairs its own agent tool")
    |> render(:home)
  end
end
