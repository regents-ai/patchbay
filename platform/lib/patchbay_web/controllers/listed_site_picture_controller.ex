defmodule PatchbayWeb.ListedSitePictureController do
  @moduledoc "Serves the picture Patchbay took of a listed site's home page for its row on /sites."

  use PatchbayWeb, :controller

  alias Patchbay.Forum

  def show(conn, %{"domain" => domain}) do
    case Forum.get_listed_site_picture(domain) do
      {:ok, picture} ->
        conn
        |> put_resp_content_type("image/webp", nil)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, picture.image)

      {:error, _not_found} ->
        send_resp(conn, 404, "")
    end
  end
end
