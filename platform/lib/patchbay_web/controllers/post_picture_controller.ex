defmodule PatchbayWeb.PostPictureController do
  @moduledoc "Serves a picture its author added to a forum post, while the post is public."

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias Patchbay.Forum.PostPicture

  def show(conn, %{"id" => id}), do: send_picture(conn, Forum.get_post_picture(id))

  # The type is one of PNG, JPEG or WebP, read from the picture's own bytes
  # when it was added, and the browser is told not to guess another.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_picture(conn, {:ok, picture}) do
    conn
    |> put_resp_content_type(PostPicture.content_type(picture), nil)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, picture.image)
  end

  defp send_picture(conn, {:error, _not_found_or_hidden}), do: send_resp(conn, 404, "")
end
