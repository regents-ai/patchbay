defmodule PatchbayWeb.SearchLive do
  @moduledoc """
  ash-template's shell search, with Patchbay's public pages, actions, questions
  and sites. The browser opens the dialog; current-query reads never accept an
  older answer. No private records, payments or provider calls are searched.
  """
  use Phoenix.LiveView, layout: false

  use Phoenix.VerifiedRoutes,
    endpoint: PatchbayWeb.Endpoint,
    router: PatchbayWeb.Router,
    statics: PatchbayWeb.static_paths()

  import PatchbayWeb.Forum.BoardHTML,
    only: [post_title: 1, site_name: 1, site_domain: 1, site_path: 1, count_label: 3]

  import PatchbayWeb.Forum.Icon
  alias Patchbay.Forum
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Read
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, q: "", opened?: false, search_read: %Read{})}

  def handle_event("open", _params, socket) do
    if socket.assigns.opened?,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:opened?, true) |> search()}
  end

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(:q, normalize(q)) |> search()}

  def handle_async({Read, _, _} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  defp search(socket) do
    q = socket.assigns.q
    Read.start(socket, :search_read, q, fn -> read(q) end)
  end

  defp read("") do
    with {:ok, page} <- Forum.list_recent_reports(page: [limit: 4], load: [:site]),
         {:ok, sites, _more?} <- Board.list_showcase(4),
         do: {:ok, %{questions: page.results, sites: sites}}
  end

  defp read(q) do
    with {:ok, page} <- Forum.search_threads(q, page: [limit: 12], load: [:site]),
         {:ok, sites} <- matching_sites(q),
         do: {:ok, %{questions: page.results, sites: sites}}
  end

  defp matching_sites(q) do
    if String.length(q) < 2,
      do: {:ok, []},
      else: Forum.find_sites(q, query: [limit: 12], load: [:tool_count])
  end

  defp normalize(q) when is_binary(q), do: q |> String.trim() |> String.slice(0, 100)
  defp normalize(_), do: ""

  defp named(q) do
    needle = String.downcase(q)

    [
      {"Pages",
       [
         %{kind: :page, label: "Questions", path: ~p"/questions"},
         %{kind: :page, label: "Sites", path: ~p"/sites"},
         %{kind: :page, label: "Agent Offers", path: ~p"/offers"},
         %{kind: :page, label: "Account", path: ~p"/account"},
         %{kind: :page, label: "Agent guide", path: ~p"/agents.md"},
         %{kind: :page, label: "Help", path: ~p"/help"}
       ]},
      {"Actions",
       [
         %{kind: :action, label: "Ask a question", path: ~p"/" <> "#pb-fix-goal"},
         %{kind: :action, label: "Create Offer", path: ~p"/offers/create"}
       ]}
    ]
    |> Enum.map(fn {group, items} ->
      {group, Enum.filter(items, &String.contains?(String.downcase(&1.label), needle))}
    end)
  end

  defp groups(q, value) do
    found =
      case value do
        %{questions: questions, sites: sites} ->
          [
            {"Questions",
             Enum.map(
               questions,
               &%{
                 kind: :question,
                 label: post_title(&1),
                 path: ~p"/posts/#{&1.id}",
                 detail: site_name(&1.site)
               }
             )},
            {"Sites",
             Enum.map(
               sites,
               &%{
                 kind: :site,
                 label: site_name(&1),
                 path: site_path(&1),
                 detail:
                   site_domain(&1) <>
                     " · " <> count_label(&1.tool_count, "WebMCP tool", "WebMCP tools")
               }
             )}
          ]

        _ ->
          []
      end

    Enum.reject(named(q) ++ found, fn {_group, items} -> items == [] end)
  end

  def render(assigns) do
    read = assigns.search_read
    search = %{query: assigns.q, results: groups(assigns.q, read.value), state: read.state}

    assigns =
      assign(assigns,
        search: search,
        read_state: read.state,
        drawn_query: if(read.state in [:idle, :ready, :empty], do: assigns.q)
      )

    ~H"""
    <Regent.Structure.dialog
      id="shell-search"
      class="shell-search"
      phx-hook="SearchDialog"
      aria-label="Search"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <form id="shell-search-form" role="search" phx-change="search" phx-submit="search">
        <.icon name={:search} class="pb-icon shell-search__glass" />
        <input
          id="shell-search-input"
          name="q"
          type="search"
          value={@search.query}
          role="combobox"
          aria-label="Search"
          aria-expanded="true"
          aria-controls="shell-search-results"
          aria-autocomplete="list"
          autocomplete="off"
          spellcheck="false"
          maxlength="100"
          phx-debounce="150"
          phx-mounted={JS.ignore_attributes(["aria-activedescendant"])}
          placeholder="Search pages, actions, questions and sites"
        />
        <button type="button" class="shell-search__close" data-search-close>
          <kbd class="shell-search__esc">Esc</kbd>
          <span class="shell-search__close-word">Close</span>
        </button>
      </form>
      <div
        id="shell-search-results"
        role="listbox"
        aria-label="Results"
        data-query={@drawn_query}
      >
        <p :if={@read_state == :loading} class="shell-search__empty" role="status">Searching…</p>
        <p :if={@read_state in [:error, :stale]} class="shell-search__empty" role="alert">
          {if @read_state == :stale,
            do: "Search could not refresh. Previous results are shown.",
            else: "Search is unavailable right now. Try again in a moment."}
        </p>
        <div
          :if={
            @read_state not in [:loading, :error, :stale] and @search.query != "" and
              @search.results == []
          }
          class="shell-search__empty"
        >
          <.icon name={:search} />
          <p><strong>No results for “{@search.query}”</strong></p>
          <p>Try a page name, a site or words from a question.</p>
        </div>
        <section
          :for={{{group, items}, g} <- Enum.with_index(@search.results)}
          role="group"
          aria-labelledby={"shell-search-group-#{g}"}
        >
          <h3 id={"shell-search-group-#{g}"}>
            {group} <span class="shell-search__count">{length(items)}</span>
          </h3>
          <.link
            :for={{item, i} <- Enum.with_index(items)}
            id={"shell-search-result-#{g}-#{i}"}
            href={item.path}
            role="option"
            aria-selected="false"
            data-search-result
            phx-mounted={JS.ignore_attributes(["aria-selected"])}
          >
            <span class="shell-search__kind" data-kind={item.kind}>
              <.icon name={kind_icon(item.kind)} />
            </span>
            <span class="shell-search__text">
              <span class="shell-search__label">{marked(item.label, @search.query)}</span>
              <span :if={item[:detail]} class="shell-search__detail">
                {marked(item.detail, @search.query)}
              </span>
            </span>
            <kbd class="shell-search__enter" aria-hidden="true">↵</kbd>
          </.link>
        </section>
      </div>
      <div :if={@search.query != ""} class="shell-search__browse">
        <.link href={~p"/?#{[q: @search.query]}"}>
          See all questions for “{@search.query}” →
        </.link>
      </div>
      <p id="shell-search-status" class="visually-hidden" aria-live="polite">
        {result_count(@search)}
      </p>
      <footer class="shell-search__footer" aria-hidden="true">
        <span><kbd>↑</kbd><kbd>↓</kbd> Move</span>
        <span><kbd>↵</kbd> Open</span>
        <span><kbd>Esc</kbd> Close</span>
      </footer>
    </Regent.Structure.dialog>
    """
  end

  defp kind_icon(:page), do: :page
  defp kind_icon(:action), do: :action
  defp kind_icon(:question), do: :reply
  defp kind_icon(:site), do: :link

  defp result_count(%{state: :loading}), do: "Searching…"
  defp result_count(%{state: state}) when state in [:error, :stale], do: "Search unavailable"
  defp result_count(%{query: ""}), do: ""

  defp result_count(%{results: results}) do
    case Enum.sum(Enum.map(results, fn {_group, items} -> length(items) end)) do
      0 -> "No results"
      1 -> "1 result"
      count -> "#{count} results"
    end
  end

  # The template's escaped first-match highlight, including literal punctuation.
  defp marked(text, ""), do: text

  defp marked(text, query) do
    case Regex.split(~r/#{Regex.escape(query)}/iu, text, parts: 2, include_captures: true) do
      [before, match, rest] ->
        {:safe, [escape(before), "<mark>", escape(match), "</mark>", escape(rest)]}

      [_unmatched] ->
        text
    end
  end

  defp escape(text), do: Phoenix.HTML.Engine.html_escape(text)
end
