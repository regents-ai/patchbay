defmodule PatchbayWeb.NewestThreadsLive do
  @moduledoc """
  The strip across the top of the front page: the newest threads on the
  board, newest first, each one a link to its thread. It listens for a new
  thread, or one moderation takes out of sight or puts back, and reads the
  list again the moment either happens. Only a thread that arrives while the
  page is open is marked as new, so the strip moves when something happens
  and is still otherwise.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [ago: 1, moment: 1, post_title: 1, site_name: 1]

  alias Patchbay.Forum.Report
  alias PatchbayWeb.Forum.Board

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Report.threads_topic())

    {:ok, assign(socket, threads: Board.newest_threads(), arrived: MapSet.new())}
  end

  @impl true
  def handle_info(:threads_changed, socket) do
    shown = MapSet.new(socket.assigns.threads, & &1.id)
    threads = Board.newest_threads()
    arrived = for thread <- threads, thread.id not in shown, into: MapSet.new(), do: thread.id

    {:noreply, assign(socket, threads: threads, arrived: arrived)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="pb-newest" aria-labelledby="pb-newest-title">
      <h2 id="pb-newest-title" class="pb-newest-label">
        <span class="pb-newest-dot" aria-hidden="true"></span> Newest posts
      </h2>
      <ol :if={@threads != []} class="pb-newest-list">
        <li
          :for={thread <- @threads}
          id={"pb-newest-#{thread.id}"}
          class={thread.id in @arrived && "is-arriving"}
        >
          <a href={~p"/posts/#{thread.id}"}>
            <span class="pb-newest-site">{site_name(thread.site)}</span>
            <span class="pb-newest-title">{post_title(thread)}</span>
            <time
              id={"pb-newest-at-#{thread.id}"}
              datetime={DateTime.to_iso8601(thread.inserted_at)}
              title={moment(thread.inserted_at)}
              phx-hook="PatchbayRelativeTime"
            >
              {ago(thread.inserted_at)}
            </time>
          </a>
        </li>
      </ol>
      <p :if={@threads == []} class="pb-newest-empty">
        No posts yet. <a href={~p"/ask"}>Ask the first question</a>.
      </p>
    </section>
    """
  end
end
