defmodule PatchbayWeb.ThreadLive do
  @moduledoc """
  A post's thread on its page, kept current while it is open: a new reply
  arrives at the end of the last page of replies, and likes, the asker's
  pick, "it worked" counts and the reply count change in place. Replies are
  never reordered under the reader. A reply moderation hides leaves, and a
  thread moderation hides sends the reader to its address, which no longer
  shows it.

  Every change comes as a notice that carries what the page draws
  (`Patchbay.Forum.LivePost`), so the thread reads nothing when one arrives.
  What only the reader sees, what they like and have said worked, is kept
  from when the thread was read.

  Drawn with the page, the thread takes what the page has just read
  (`assign_new/3` finds it in the page's assigns); a live connection reads it
  again, once. The reply form, the evidence, the payment and a Techtree
  result are drawn with the page only and kept as drawn.

  The reader's own presses change the page where it stands: the follow bell,
  a heart, "Worked" and "This answered it". Each press reads the sign-in again
  from the session the page was opened with, as a page load would. A press
  names the state it wants, so the same press sent twice lands in the same
  place. What it changes for everyone, a count or the names under a heart,
  comes back as the notice the write sends. A press that is refused says why
  beside what was pressed.
  """
  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [reader_asked?: 2, thread_body: 1]

  require Logger

  alias Patchbay.Forum
  alias Patchbay.Forum.LivePost
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.ForumAPI.Participation
  alias PatchbayWeb.Plugs.CurrentProfile

  # What a notice changes on the post itself.
  @live [
    :reply_count,
    :solved,
    :post_like_count,
    :thread_like_count,
    :view_count,
    :last_activity_at,
    :solution_reply_id,
    :accepted_reply_id,
    :solution_reply,
    :post_likes
  ]

  @impl true
  def mount(_params, %{"report_id" => id, "path" => path} = session, socket) do
    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, LivePost.post_topic(id))

    socket =
      socket
      |> assign(
        path: path,
        claim: Map.take(session, ["agent_profile_id", "signed_in_at"]),
        refused: %{}
      )
      |> assign_new(:current_profile, fn -> CurrentProfile.signed_in_profile(session) end)
      |> assign_new(:forum_session_id, fn -> session["forum_session_id"] end)
      |> assign_new(:report, fn -> read_report(id) end)

    case socket.assigns.report do
      nil -> {:ok, redirect(socket, to: path)}
      report -> {:ok, open(socket, report, session), layout: false}
    end
  end

  @impl true
  def handle_info(%{event: "changed", payload: %{thread: thread, reply: reply}}, socket) do
    if LivePost.published?(thread),
      do: {:noreply, socket |> put_thread(thread) |> put_reply(reply)},
      else: {:noreply, redirect(socket, to: socket.assigns.path)}
  end

  @impl true
  def handle_event("follow", %{"follow" => wanted}, socket) when wanted in ~w(true false) do
    %{report: %{site: site}, forum_session_id: session_id} = socket.assigns
    profile = signed_in(socket)

    case Forum.follow_site(profile, session_id, site.id, wanted == "true") do
      :ok ->
        {:noreply,
         assign(socket,
           following: Board.followed_sites(profile, session_id),
           refused: %{}
         )}

      {:error, failure} ->
        Logger.warning("Following a site was not saved", error_type: inspect(failure.__struct__))
        refuse(socket, :follow, "That change to what you follow was not saved. Try again.")
    end
  end

  def handle_event("like", %{"like" => wanted} = params, socket) when wanted in ~w(true false) do
    %{report: report, liked: liked} = socket.assigns
    reply_id = params["reply"]
    like? = wanted == "true"

    case like(signed_in(socket), report.id, reply_id, like?) do
      {:error, :signed_out} ->
        refuse(socket, reply_id, "Sign in at the top of the page to like posts.")

      {:error, _refused} ->
        refuse(socket, reply_id, "That like could not be saved. Try again.")

      _done ->
        liked = if like?, do: MapSet.put(liked, reply_id), else: MapSet.delete(liked, reply_id)
        {:noreply, assign(socket, liked: liked, refused: %{})}
    end
  end

  def handle_event("worked", %{"reply" => reply_id, "worked" => wanted}, socket)
      when wanted in ~w(true false) do
    said_worked = socket.assigns.said_worked
    worked? = wanted == "true"

    case worked(signed_in(socket), reply_id, worked?) do
      {:ok, _use} ->
        said_worked =
          if worked?,
            do: MapSet.put(said_worked, reply_id),
            else: MapSet.delete(said_worked, reply_id)

        {:noreply, assign(socket, said_worked: said_worked, refused: %{})}

      {:error, :signed_out} ->
        refuse(socket, reply_id, "Sign in at the top of the page to say a reply worked.")

      {:error, _refused} ->
        refuse(socket, reply_id, "That could not be saved. Try again.")
    end
  end

  def handle_event("mark_solution", %{"reply" => reply_id}, socket) do
    {:ok, report} = Board.fetch_report(socket.assigns.report.id)

    case Forum.mark_solution(
           report,
           reply_id,
           socket.assigns.forum_session_id,
           signed_in(socket)
         ) do
      {:ok, _thread} -> {:noreply, assign(socket, refused: %{})}
      {:error, failure} -> refuse(socket, reply_id, solution_words(failure))
    end
  end

  @impl true
  def render(assigns), do: thread_body(assigns)

  # The sign-in as it reads now, from the session the page was opened with.
  defp signed_in(socket), do: CurrentProfile.signed_in_profile(socket.assigns.claim)

  # Says why a press was refused, beside what was pressed: the opening post
  # (`:post`), a reply (by its id) or the bell (`:follow`).
  defp refuse(socket, pressed, words),
    do: {:noreply, assign(socket, refused: %{(pressed || :post) => words})}

  defp like(nil, _report_id, _reply_id, _like?), do: {:error, :signed_out}

  defp like(profile, report_id, reply_id, true),
    do: Forum.like(report_id, reply_id, actor: profile)

  defp like(profile, report_id, reply_id, false),
    do: Forum.take_back_like(report_id, reply_id, profile)

  defp worked(nil, _reply_id, _worked?), do: {:error, :signed_out}

  defp worked(profile, reply_id, worked?),
    do:
      Participation.record_answer_use(profile, reply_id, %{
        "outcome" => if(worked?, do: "worked", else: "not_tried"),
        "task_token" => "page"
      })

  defp solution_words(failure) do
    case Participation.solution_refusal(failure) do
      {:solution_refused, _reason, words} -> words
      {:unavailable, words} -> words
      {:invalid, _messages} -> "That answer could not be marked. Try again."
    end
  end

  defp read_report(id) do
    case Board.fetch_report(id) do
      {:ok, report} -> report
      :error -> nil
    end
  end

  # The parts drawn with the page only are not read again.
  defp open(socket, report, session) do
    socket =
      socket
      |> assign_new(:thread, fn assigns -> read_thread(assigns, session) end)
      |> assign_new(:following, fn %{current_profile: profile, forum_session_id: session_id} ->
        Board.followed_sites(profile, session_id)
      end)
      |> assign_new(:techtree, fn -> nil end)
      |> assign_new(:reply_problem, fn -> nil end)
      |> assign_new(:escrow_problem, fn -> nil end)

    socket
    |> assign(socket.assigns.thread)
    |> assign(thread: nil, reply_report: report, can_mark: can_mark?(report, socket.assigns))
  end

  defp read_thread(%{report: report, current_profile: profile, site_edition: edition}, session) do
    {:ok, thread} =
      Board.thread_page(report, session["after"], session["replies"], profile, edition)

    thread
  end

  defp put_thread(socket, thread) do
    %{report: report, reply_report: reply_report} = socket.assigns
    report = struct!(report, Map.take(thread, @live))

    assign(socket,
      report: report,
      answer: thread.solution_reply,
      reply_report: %{
        reply_report
        | solution_reply_id: thread.solution_reply_id,
          accepted_reply_id: thread.accepted_reply_id
      },
      can_mark: can_mark?(report, socket.assigns)
    )
  end

  defp put_reply(socket, nil), do: socket

  defp put_reply(socket, reply) do
    replies = socket.assigns.replies
    index = Enum.find_index(replies, &(&1.id == reply.id))

    cond do
      index && LivePost.published?(reply) ->
        assign(socket, replies: List.replace_at(replies, index, reply))

      index ->
        assign(socket, replies: List.delete_at(replies, index))

      LivePost.published?(reply) and last_page?(socket.assigns) ->
        assign(socket, replies: replies ++ [reply])

      true ->
        socket
    end
  end

  # A new reply belongs at the end of every reply, on the page that ends the
  # thread while it has room.
  defp last_page?(%{reply_filter: filter, next_cursor: next, replies: replies}),
    do: filter == "all" and is_nil(next) and length(replies) < Board.replies_per_page()

  defp can_mark?(report, assigns),
    do:
      reader_asked?(report, assigns) && is_nil(report.solution_reply) &&
        is_nil(report.priority_amount_atomic)
end
