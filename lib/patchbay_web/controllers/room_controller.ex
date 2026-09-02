defmodule PatchbayWeb.RoomController do
  use PatchbayWeb, :controller

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, RoomCapacity}

  @session_key "patchbay_room_slug"

  # Every visitor gets a room of their own, so a second person never walks into
  # a room somebody else already repaired. The slug is remembered in the
  # browser session, which is how a returning visitor lands back in the room
  # they left rather than a fresh one.
  def enter(conn, _params) do
    case remembered_slug(conn) do
      {:ok, slug} ->
        redirect(conn, to: ~p"/webmcp/rooms/#{slug}")

      :none ->
        open_room(conn)
    end
  end

  defp open_room(conn) do
    case RoomCapacity.create_room(new_slug()) do
      {:ok, room} ->
        conn
        |> put_session(@session_key, room.slug)
        |> redirect(to: ~p"/webmcp/rooms/#{room.slug}")

      {:error, :at_capacity} ->
        conn
        |> put_status(:service_unavailable)
        |> put_view(html: PatchbayWeb.RoomHTML)
        |> assign(:page_title, "All rooms are busy")
        |> render(:busy)
    end
  end

  defp remembered_slug(conn) do
    with slug when is_binary(slug) <- get_session(conn, @session_key),
         %Room{} <- lookup(slug) do
      {:ok, slug}
    else
      _ -> :none
    end
  end

  # A remembered room can be gone: unused rooms are swept away after a while.
  # Only an absent room reads as "start a new one"; a database failure still
  # raises and is not mistaken for a missing room.
  defp lookup(slug), do: Domain.get_room_by_slug!(slug, not_found_error?: false)

  defp new_slug do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
