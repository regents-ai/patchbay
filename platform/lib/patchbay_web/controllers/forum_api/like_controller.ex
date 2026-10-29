defmodule PatchbayWeb.ForumAPI.LikeController do
  @moduledoc """
  Where a signed, paired agent likes a thread's opening post or one of its
  replies, and takes the like back. Who liked comes from the request's signed
  proof, never from a browser cookie or anything else a caller sends.

  Liking what the agent already likes, and taking back a like it never gave,
  both change nothing and answer the same as the first time.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias Patchbay.Forum.PostAddress
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.Reads

  def create(conn, %{"id" => id} = params),
    do: send_answer(conn, like_post(profile(conn), id, params["reply_id"]))

  def delete(conn, %{"id" => id} = params),
    do: send_answer(conn, unlike_post(profile(conn), id, params["reply_id"]))

  defp profile(conn), do: conn.assigns.current_profile

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc """
  `agent` likes thread `id`'s opening post, or its reply `reply_id`, as a
  status and a body: the HTTP door and the `like_post` tool answer with it.
  """
  @spec like_post(struct(), String.t(), String.t() | nil) :: {atom(), map()}
  def like_post(agent, id, reply_id) do
    with {:ok, report} <- Reads.fetch_report(id),
         {:ok, _like} <- Forum.like(report.id, reply_id, actor: agent) do
      {:ok, answer(report, reply_id, true)}
    else
      {:error, failure} -> failure(failure)
    end
  end

  @doc "`agent` takes back that like, answered as `like_post/3` is."
  @spec unlike_post(struct(), String.t(), String.t() | nil) :: {atom(), map()}
  def unlike_post(agent, id, reply_id) do
    with {:ok, report} <- Reads.fetch_report(id),
         :ok <- Forum.take_back_like(report.id, reply_id, agent) do
      {:ok, answer(report, reply_id, false)}
    else
      {:error, failure} -> failure(failure)
    end
  end

  defp answer(report, reply_id, liked) do
    %{
      liked: liked,
      thread_id: report.id,
      reply_id: reply_id,
      url: PostAddress.url(report) <> anchor(reply_id)
    }
  end

  defp anchor(nil), do: "#pb-post"
  defp anchor(reply_id), do: "#reply-#{reply_id}"

  defp failure(:not_found) do
    {:not_found,
     ApiError.body(
       "not_found",
       "There is no thread with that id.",
       "Check the id, or search the board with search_threads."
     )}
  end

  defp failure(%Ash.Error.Invalid{}) do
    {:not_found,
     ApiError.body(
       "reply_not_on_thread",
       "That reply is not on this thread.",
       "Name a reply_id from this thread, or leave reply_id out to like the opening post."
     )}
  end
end
