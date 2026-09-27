defmodule PatchbayWeb.NewestThreadsLive do
  @moduledoc """
  The strip across the top of the front page: the newest threads on the
  board, newest first, each one a link to its thread. It listens for a new
  thread, or one moderation takes out of sight or puts back, and reads the
  list again the moment either happens. Only a thread that arrives while the
  page is open is marked as new, so the strip moves when something happens
  and is still otherwise.

  The list is one `PatchbayWeb.Read`. The first read happens while the page
  is drawn, so the strip is there without JavaScript; later reads run beside
  the page and keep the list on screen while they do. A read that fails says
  so: the strip marks a kept list as possibly out of date, or says the posts
  could not be loaded, and offers to try again.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [ago: 1, moment: 1, post_title: 1, site_name: 1]

  alias Patchbay.Forum.Report
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Motion
  alias PatchbayWeb.Read

  # Every visitor sees the same strip, so the board itself owns the read.
  @owner :board

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, Report.threads_topic())

    {:ok,
     socket
     |> assign(threads: %Read{owner: @owner}, arrived: MapSet.new())
     |> Read.settle({Read, :threads, 0}, {:ok, Board.newest_threads()})}
  end

  @impl true
  def handle_info(:threads_changed, socket), do: {:noreply, read_threads(socket)}

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, read_threads(socket)}

  @impl true
  def handle_async({Read, :threads, _generation} = name, result, socket) do
    shown = socket.assigns.threads
    socket = Read.settle(socket, name, result)
    {:noreply, assign(socket, arrived: arrived(shown, socket.assigns.threads))}
  end

  defp read_threads(socket), do: Read.start(socket, :threads, @owner, &Board.newest_threads/0)

  # A thread is new only when it joins a list that was already on screen.
  defp arrived(%Read{read_at: nil}, _now), do: MapSet.new()
  defp arrived(_before, %Read{state: state}) when state not in [:ready, :empty], do: MapSet.new()

  defp arrived(before, now) do
    shown = MapSet.new(before.value || [], & &1.id)
    for thread <- now.value || [], thread.id not in shown, into: MapSet.new(), do: thread.id
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="pb-newest" aria-labelledby="pb-newest-title">
      <h2 id="pb-newest-title" class="pb-newest-label">
        <span class="pb-newest-dot" aria-hidden="true"></span> Newest posts
      </h2>
      <ol
        :if={@threads.value not in [nil, []]}
        id="pb-newest-list"
        class="pb-newest-list"
        phx-hook="PatchbayLayout"
        data-layout-id="pb-newest-list"
        data-children="[data-thread]"
        data-variant={Motion.standard("list")}
      >
        <li
          :for={thread <- @threads.value}
          id={"pb-newest-#{thread.id}"}
          data-thread
          data-layout-id={"pb-newest-#{thread.id}"}
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
      <p :if={@threads.state == :empty} class="pb-newest-empty">
        No posts yet. <a href={~p"/ask"}>Ask the first question</a>.
      </p>
      <p :if={@threads.state == :loading and is_nil(@threads.read_at)} class="pb-newest-empty">
        Loading the newest posts…
      </p>
      <p :if={@threads.state in [:stale, :error]} class="pb-newest-empty" role="status">
        {if @threads.state == :stale,
          do: "These may be out of date: the newest posts could not be loaded again.",
          else: "The newest posts could not be loaded just now."}
        <button type="button" class="pb-newest-retry" phx-click="retry">Try again</button>
      </p>
    </section>
    """
  end
end
