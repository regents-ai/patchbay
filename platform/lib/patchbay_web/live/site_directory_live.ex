defmodule PatchbayWeb.SiteDirectoryLive do
  @moduledoc """
  The public site directory. A row opens on the picture Patchbay took of the
  site's home page and its WebMCP tools, and changes as Patchbay's checks of
  its sites finish.
  """
  use PatchbayWeb, :live_view

  alias Patchbay.Forum.SiteDirectory

  def mount(_params, session, socket) do
    # The page asked for was checked before this page was rendered.
    {:ok, page} = SiteDirectory.page(session["filters"])

    socket =
      socket
      |> assign(page: page, expanded: MapSet.new(), subscribed: MapSet.new())
      |> stream_configure(:sites, dom_id: &"directory-#{&1.host}")
      |> stream(:sites, page.sites)
      |> subscribe_sites(page.sites)

    {:ok, socket}
  end

  def handle_event("load-more", _params, socket) do
    page = socket.assigns.page

    if page.page < page.pages do
      {:ok, next} =
        SiteDirectory.page(%{
          "q" => page.q,
          "category" => page.category,
          "page" => to_string(page.page + 1)
        })

      merged = %{next | sites: page.sites ++ next.sites}

      {:noreply,
       socket
       |> assign(page: merged)
       |> stream(:sites, next.sites)
       |> subscribe_sites(next.sites)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle", %{"host" => host}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      cond do
        MapSet.member?(expanded, host) -> MapSet.delete(expanded, host)
        Enum.any?(socket.assigns.page.sites, &(&1.host == host)) -> MapSet.put(expanded, host)
        true -> expanded
      end

    socket = assign(socket, expanded: expanded)
    site = Enum.find(socket.assigns.page.sites, &(&1.host == host))
    {:noreply, if(site, do: stream_insert(socket, :sites, site), else: socket)}
  end

  def handle_info(%Ash.Notifier.Notification{data: check}, socket) do
    page = SiteDirectory.replace_check(socket.assigns.page, check)
    socket = assign(socket, page: page)
    {:noreply, stream(socket, :sites, Enum.filter(page.sites, &(&1.domain == check.domain)))}
  end

  def render(assigns) do
    ~H"""
    <section id="site-directory" class="pb-site-directory" aria-labelledby="directory-heading">
      <header class="pb-directory-intro">
        <div>
          <h2 id="directory-heading">All sites</h2>
        </div>
        <span class="pb-directory-total">
          {metric(@page.total)} {if @page.total == 1, do: "site", else: "sites"}
        </span>
      </header>

      <form action="/sites" method="get" class="pb-directory-search" role="search">
        <label class="pb-directory-search-field">
          <span class="visually-hidden">Search sites</span>
          <input type="search" name="q" value={@page.q} maxlength="100" placeholder="Search websites" />
        </label>
        <label class="pb-directory-select">
          <span class="visually-hidden">Category</span>
          <select name="category">
            <option value="">All categories</option>
            <option
              :for={category <- SiteDirectory.categories()}
              value={category}
              selected={@page.category == category}
            >
              {category_label(category, @site_edition)}
            </option>
          </select>
        </label>
        <button class="rg-button rg-button--secondary" type="submit">Search</button>
      </form>
      <div :if={@page.q != ""} class="pb-directory-results-heading">
        <p role="status">
          <span>Results for “{@page.q}”</span>
        </p>
        <p>{length(@page.sites)} / {metric(@page.total)}</p>
      </div>

      <div
        :if={@page.sites != []}
        class="pb-directory-scroll"
        role="region"
        aria-label="Website listings"
      >
        <table id="directory-table" class="pb-directory-table">
          <caption id="directory-caption" class="visually-hidden">
            WebMCP websites, tool counts and public forum posts
          </caption>
          <thead id="directory-columns">
            <tr>
              <th scope="col">Website</th>
              <th scope="col" class="pb-directory-numeric">Tools</th>
              <th scope="col" class="pb-directory-numeric">Posts</th>
            </tr>
          </thead>
          <tbody
            id="directory-rows"
            phx-update="stream"
            phx-hook="MotionArrivals"
            phx-viewport-bottom={if @page.page < @page.pages, do: "load-more"}
          >
            <tr :for={{dom_id, site} <- @streams.sites} id={dom_id} class="pb-directory-row">
              <th scope="row">
                <div class="pb-directory-identity">
                  <button
                    type="button"
                    class="pb-directory-expand"
                    phx-click="toggle"
                    phx-value-host={site.host}
                    aria-expanded={to_string(MapSet.member?(@expanded, site.host))}
                    aria-controls={"tools-" <> site.host}
                  >
                    <span class="pb-directory-mark" aria-hidden="true">
                      <img
                        :if={site.logo_path}
                        src={site.logo_path}
                        alt=""
                        width="28"
                        height="28"
                        loading="lazy"
                      />
                      <span :if={!site.logo_path}>{initial(site.name)}</span>
                    </span>
                    <span class="pb-directory-name">{site.name}</span>
                  </button>
                  <div class="pb-directory-url">
                    <a href={site.page_url} rel="noopener noreferrer" target="_blank">{site.host}<span class="visually-hidden"> (opens website)</span></a>
                  </div>
                  <a class="pb-directory-forum" href={"/" <> site.domain}>
                    <span>View Forum</span><span class="visually-hidden"> for {site.name}</span>
                  </a>
                </div>
                <div
                  id={"tools-" <> site.host}
                  class="pb-directory-detail-inner"
                  hidden={!MapSet.member?(@expanded, site.host)}
                >
                  <img
                    :if={site.screenshot_path}
                    class="pb-directory-picture"
                    src={site.screenshot_path}
                    alt={site.name <> " home page"}
                    width="1600"
                    height="1000"
                    loading="lazy"
                    decoding="async"
                  />
                  <ul
                    :if={site.tools != []}
                    class="pb-directory-tool-list"
                    tabindex="0"
                    aria-label={"WebMCP tools on " <> site.name}
                  >
                    <li :for={tool <- site.tools}><code>{tool["name"]}</code></li>
                  </ul>
                  <p :if={site.tools == []} class="pb-directory-empty">No tool names recorded yet.</p>
                </div>
              </th>
              <td class="pb-directory-numeric">
                <button
                  type="button"
                  class="pb-directory-count"
                  phx-click="toggle"
                  phx-value-host={site.host}
                  aria-label={"View tools for " <> site.name}
                  aria-expanded={to_string(MapSet.member?(@expanded, site.host))}
                  aria-controls={"tools-" <> site.host}
                >
                  <strong>{metric(site.tool_count)}</strong>
                </button>
              </td>
              <td class="pb-directory-numeric">
                <a
                  href={"/" <> site.domain}
                  class="pb-directory-posts"
                  aria-label={"Public posts for " <> site.domain}
                >
                  {metric(site.forum_posts)}
                </a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <Regent.Primitives.empty_state
        :if={@page.sites == [] and @page.q == "" and @page.category in [nil, ""]}
        title="No sites"
      >
        <:action>
          <a class="rg-button rg-button--secondary" href={~p"/"}>
            <span class="rg-button__label">Ask a question</span>
          </a>
        </:action>
      </Regent.Primitives.empty_state>
      <Regent.Primitives.empty_state
        :if={@page.sites == [] and (@page.q != "" or @page.category not in [nil, ""])}
        title="No matches"
      >
        <:action>
          <a class="rg-button rg-button--secondary" href={~p"/sites"}>
            <span class="rg-button__label">All sites</span>
          </a>
        </:action>
      </Regent.Primitives.empty_state>
      <div class="pb-directory-pagination">
        <button
          :if={@page.page < @page.pages}
          type="button"
          phx-click="load-more"
          phx-disable-with="Loading…"
          class="rg-button rg-button--secondary"
        >Load more sites</button>
        <p :if={@page.page == @page.pages and @page.total > 0} role="status">
          End of results
        </p>
        <noscript :if={@page.page < @page.pages}>
          <a href={SiteDirectory.page_url(@page, @page.page + 1)}>Next sites →</a>
        </noscript>
      </div>
      <p :if={@site_edition == :main} class="pb-directory-method">
        <a href={~p"/docs#directory"}>Sources</a>
      </p>
    </section>
    """
  end

  defp subscribe_sites(socket, sites) do
    domains = MapSet.new(sites, & &1.domain)

    if connected?(socket) do
      domains
      |> MapSet.difference(socket.assigns.subscribed)
      |> Enum.each(&Phoenix.PubSub.subscribe(Patchbay.PubSub, "site_check:" <> &1))
    end

    assign(socket, subscribed: MapSet.union(socket.assigns.subscribed, domains))
  end

  defp initial(name), do: name |> String.first() |> String.upcase()
  defp metric(nil), do: "—"
  defp metric(number), do: to_string(number)

  # The categories are the directory's own words. The open address names no
  # crypto in its own copy, so there only this one's label is shorter; the
  # filter keeps the directory's value.
  defp category_label("Finance & Crypto", :open), do: "Finance"
  defp category_label(category, _site_edition), do: category
end
