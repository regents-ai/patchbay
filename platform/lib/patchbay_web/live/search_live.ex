defmodule PatchbayWeb.SearchLive do
  @moduledoc """
  The search window every page shares, as on Autolaunch. Pressing the
  header's search bar or ⌘ K opens it; typing lists matching questions and
  sites inside it, and the page changes only when the reader picks one.
  """
  use Phoenix.LiveView, layout: false

  use Phoenix.VerifiedRoutes,
    endpoint: PatchbayWeb.Endpoint,
    router: PatchbayWeb.Router,
    statics: PatchbayWeb.static_paths()

  import PatchbayWeb.Forum.BoardHTML,
    only: [post_title: 1, site_name: 1, site_domain: 1, site_path: 1, count_label: 3]

  alias Patchbay.Forum
  alias PatchbayWeb.Forum.Board
  alias Phoenix.LiveView.JS

  @categories [{"all", "All"}, {"questions", "Questions"}, {"sites", "Sites"}]
  @recent_limit 5
  @most_chars 200

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       q: "",
       category: "all",
       recent: [],
       opened?: false,
       results: nil,
       results_q: "",
       failed?: false
     )}
  end

  # Nothing is read until the window first opens; the browser keeps the
  # reader's recent searches and hands them over each time it opens.
  def handle_event("open", %{"recent" => recent}, socket) do
    socket = assign(socket, recent: recent_searches(recent))

    if socket.assigns.opened?,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(opened?: true) |> search()}
  end

  def handle_event("recent", %{"recent" => recent}, socket),
    do: {:noreply, assign(socket, recent: recent_searches(recent))}

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: normalize(q)) |> search()}

  def handle_event("category", %{"category" => category}, socket)
      when category in ["all", "questions", "sites"],
      do: {:noreply, socket |> assign(category: category) |> search()}

  def handle_async(:search, {:ok, {q, {:ok, results}}}, socket),
    do: {:noreply, assign(socket, results: results, results_q: q, failed?: false)}

  def handle_async(:search, _failure, socket), do: {:noreply, assign(socket, failed?: true)}

  defp search(socket) do
    %{q: q, category: category} = socket.assigns
    start_async(socket, :search, fn -> {q, read(q, category)} end)
  end

  # "All" shows a few of each; a single kind shows more of it. With nothing
  # typed, the newest questions and the sites with WebMCP tools.
  defp read(q, category) do
    limit = if category == "all", do: 4, else: 12

    with {:ok, questions} <- records("questions", category, q, limit),
         {:ok, sites} <- records("sites", category, q, limit) do
      {:ok, %{questions: questions, sites: sites}}
    end
  end

  defp records("questions", category, "", limit) when category in ["all", "questions"] do
    with {:ok, page} <- Forum.list_recent_reports(page: [limit: limit], load: [:site]),
         do: {:ok, page.results}
  end

  defp records("questions", category, q, limit) when category in ["all", "questions"] do
    with {:ok, page} <- Forum.search_threads(q, page: [limit: limit], load: [:site]),
         do: {:ok, page.results}
  end

  defp records("sites", category, "", limit) when category in ["all", "sites"] do
    with {:ok, sites, _more?} <- Board.list_showcase(limit), do: {:ok, sites}
  end

  defp records("sites", category, q, _limit) when category in ["all", "sites"] do
    if String.length(q) < 2,
      do: {:ok, []},
      else: Forum.find_sites(q, load: [:tool_count])
  end

  defp records(_view, _category, _q, _limit), do: {:ok, []}

  defp normalize(q) when is_binary(q) do
    q |> String.split() |> Enum.join(" ") |> String.slice(0, @most_chars)
  end

  defp normalize(_q), do: ""

  defp recent_searches(recent) do
    recent
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@recent_limit)
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        categories: @categories,
        empty?: match?(%{questions: [], sites: []}, assigns.results) and not assigns.failed?
      )

    ~H"""
    <%!-- The browser, not the server, opens the window: each new list of
         results leaves it open. --%>
    <dialog
      id="search-dialog"
      class="search-dialog"
      phx-hook="SearchDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-label="Search"
      data-query={@results_q}
    >
      <%!-- The field, not the form, sends the typing: with a change binding on
           the form, LiveView would send the whole form on Enter. Enter opens
           the first result instead (SearchDialog hook). --%>
      <form id="search-dialog-form" class="search-dialog__field" role="search">
        <svg
          viewBox="0 0 24 24"
          width="20"
          height="20"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          aria-hidden="true"
        ><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
        <label for="search-dialog-q" class="visually-hidden">Search questions and sites</label>
        <input
          id="search-dialog-q"
          type="search"
          name="q"
          value={@q}
          maxlength="200"
          placeholder="Search questions and sites…"
          autocomplete="off"
          phx-change="search"
          phx-debounce="200"
        />
        <button type="button" class="search-dialog__close" data-close-search aria-label="Close search">
          <kbd>Esc</kbd><span>Close</span>
        </button>
      </form>

      <div class="search-dialog__body">
        <div class="search-dialog__categories" role="group" aria-label="Show">
          <button
            :for={{value, label} <- @categories}
            type="button"
            phx-click="category"
            phx-value-category={value}
            aria-pressed={to_string(@category == value)}
          >
            {label}
          </button>
        </div>

        <div class="search-dialog__results">
          <section :if={@q == "" and @recent != []} class="search-dialog__section">
            <header>
              <h2>Recent searches</h2>
              <button type="button" class="search-dialog__clear" data-clear-recent>Clear</button>
            </header>
            <div class="search-dialog__recent">
              <button :for={term <- @recent} type="button" phx-click="search" phx-value-q={term}>
                {term}
              </button>
            </div>
          </section>

          <p :if={is_nil(@results) and not @failed?} class="search-dialog__note">Searching…</p>
          <p :if={@failed?} class="search-dialog__note" role="alert">
            Search is unavailable right now. Try again in a moment.
          </p>
          <p :if={@empty?} class="search-dialog__note">
            {if @results_q == "", do: "Nothing here yet.", else: "Nothing matches “#{@results_q}”."}
          </p>

          <section
            :if={@results && @results.questions != [] && !@failed?}
            class="search-dialog__section"
          >
            <h2>{if @results_q == "", do: "Newest questions", else: "Questions"}</h2>
            <a
              :for={question <- @results.questions}
              href={~p"/posts/#{question.id}"}
              class="search-result"
              data-search-result
            >
              <span class="search-result__title">{post_title(question)}</span>
              <small>{site_name(question.site)}</small>
            </a>
          </section>

          <section
            :if={@results && @results.sites != [] && !@failed?}
            class="search-dialog__section"
          >
            <h2>{if @results_q == "", do: "Sites with WebMCP tools", else: "Sites"}</h2>
            <a
              :for={site <- @results.sites}
              href={site_path(site)}
              class="search-result"
              data-search-result
            >
              <span class="search-result__title">
                {site_name(site)} <small>{site_domain(site)}</small>
              </span>
              <small :if={site.tool_count > 0}>
                {count_label(site.tool_count, "WebMCP tool", "WebMCP tools")}
              </small>
            </a>
          </section>

          <a :if={@q != ""} href={~p"/?#{[q: @q]}"} class="search-dialog__all" data-search-all>
            See all questions for “{@q}”
          </a>
        </div>
      </div>
    </dialog>
    """
  end
end
