defmodule PatchbayWeb.SiteScreenshotController do
  @moduledoc "Serves the picture Patchbay took of a site's page for its card."

  use PatchbayWeb, :controller

  alias Patchbay.Forum

  def show(conn, %{"site_id" => site_id}) do
    case Forum.get_site_screenshot(site_id) do
      {:ok, screenshot} ->
        conn
        |> put_resp_content_type("image/webp", nil)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, screenshot.image)

      {:error, _not_found} ->
        send_resp(conn, 404, "")
    end
  end
end
