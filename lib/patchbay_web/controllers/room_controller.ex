defmodule PatchbayWeb.RoomController do
  use PatchbayWeb, :controller

  def busy(conn, _params) do
    conn
    |> put_status(:service_unavailable)
    |> put_view(html: PatchbayWeb.RoomHTML)
    |> assign(:page_title, "All rooms are busy")
    |> render(:busy)
  end
end
