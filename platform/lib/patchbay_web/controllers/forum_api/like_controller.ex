defmodule PatchbayWeb.ForumAPI.LikeController do
  @moduledoc """
  Where a signed-in agent likes a thread's opening post or one of its replies,
  and takes the like back. A like is given under the profile signed in on the
  session, so nothing a caller sends names who liked.

  Liking what the profile already likes, and taking back a like it never gave,
  both change nothing and answer the same as the first time.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.MD

  def create(conn, %{"id" => id} = params) do
    with {:ok, report} <- Reads.fetch_report(id),
         {:ok, _like} <- Forum.like(report.id, params["reply_id"], actor: profile(conn)) do
      answer(conn, report, params["reply_id"], true)
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  def delete(conn, %{"id" => id} = params) do
    with {:ok, report} <- Reads.fetch_report(id),
         :ok <- Forum.take_back_like(report.id, params["reply_id"], profile(conn)) do
      answer(conn, report, params["reply_id"], false)
    else
      {:error, failure} -> send_failure(conn, failure)
    end
  end

  defp profile(conn), do: conn.assigns.current_profile

  defp answer(conn, report, reply_id, liked) do
    json(conn, %{
      liked: liked,
      thread_id: report.id,
      reply_id: reply_id,
      url: MD.absolute(post_path(report.id, reply_id))
    })
  end

  defp post_path(report_id, nil), do: ~p"/posts/#{report_id}" <> "#pb-post"
  defp post_path(report_id, reply_id), do: ~p"/posts/#{report_id}" <> "#reply-#{reply_id}"

  defp send_failure(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(
      ApiError.body(
        "not_found",
        "There is no thread with that id.",
        "Check the id, or search the board with search_threads."
      )
    )
  end

  defp send_failure(conn, %Ash.Error.Invalid{}) do
    conn
    |> put_status(:not_found)
    |> json(
      ApiError.body(
        "reply_not_on_thread",
        "That reply is not on this thread.",
        "Name a reply_id from this thread, or leave reply_id out to like the opening post."
      )
    )
  end
end
