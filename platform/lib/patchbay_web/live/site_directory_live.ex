defmodule PatchbayWeb.SiteDirectoryLive do
  @moduledoc "The public site directory, with visitor-requested daily refreshes and job completion updates."
  use PatchbayWeb, :live_view

  alias Patchbay.Forum.SiteDirectory
  alias PatchbayWeb.Forum.SiteChecks

  def mount(_params, session, socket) do
    page = SiteDirectory.page(session["filters"])

    if connected?(socket) do
      page.sites
      |> Enum.map(& &1.domain)
      |> Enum.uniq()
      |> Enum.each(&Phoenix.PubSub.subscribe(Patchbay.PubSub, "site_check:" <> &1))
    end

    {:ok,
     assign(socket, page: page, visitor: session["visitor"], problem: nil, expanded: MapSet.new())}
  end

  def handle_event("toggle", %{"host" => host}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      cond do
        MapSet.member?(expanded, host) -> MapSet.delete(expanded, host)
        Enum.any?(socket.assigns.page.sites, &(&1.host == host)) -> MapSet.put(expanded, host)
        true -> expanded
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("update", %{"host" => host}, socket) do
    case Enum.find(socket.assigns.page.sites, &(&1.host == host)) do
      nil ->
        {:noreply, assign(socket, problem: "Choose a site from this page.")}

      site ->
        {status, check} =
          SiteChecks.ask(
            site.domain,
            SiteChecks.current(site.domain),
            socket.assigns.visitor,
            :directory
          )

        page =
          if check,
            do: SiteDirectory.replace_check(socket.assigns.page, check),
            else: socket.assigns.page

        problem =
          if status == :limited, do: "You've updated several sites. Try again in a few minutes."

        {:noreply, assign(socket, page: page, problem: problem)}
    end
  end

  def handle_info(%Ash.Notifier.Notification{data: check}, socket) do
    {:noreply, assign(socket, page: SiteDirectory.replace_check(socket.assigns.page, check))}
  end

  def render(assigns) do
    ~H"""
    <section id="site-directory" class="pb-site-directory" aria-labelledby="directory-heading">
      <header class="pb-directory-intro">
        <div>
          <p class="patchbay-kicker">PATCHBAY / DIRECTORY</p>
          <h1 id="directory-heading">WebMCP Sites</h1>
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
        <label>
          <span class="visually-hidden">Category</span>
          <select name="category">
            <option value="">All categories</option>
            <option
              :for={category <- SiteDirectory.categories()}
              value={category}
              selected={@page.category == category}
            >
              {category}
            </option>
          </select>
        </label>
        <button class="rg-button rg-button--secondary" type="submit">Search</button>
      </form>
      <div class="pb-directory-results-heading">
        <p role="status">
          <span :if={@page.q != ""}>Results for “{@page.q}”</span>
          <span :if={@page.q == ""}>Explore websites and their agent tools</span>
        </p>
        <p>Page {@page.page} / {@page.pages}</p>
      </div>
      <p :if={@problem} role="alert" class="pb-directory-notice">{@problem}</p>
      <p :if={!@page.cache_available?} role="status" class="pb-directory-notice">
        Saved listings are available. Refresh is temporarily unavailable.
      </p>

      <div class="pb-directory-scroll" role="region" aria-label="Website listings" tabindex="0">
        <table class="pb-directory-table">
          <caption class="visually-hidden">
            WebMCP websites, tool counts and public forum posts
          </caption>
          <thead>
            <tr>
              <th scope="col">Website</th>
              <th scope="col" class="pb-directory-numeric">WebMCP tools</th>
              <th scope="col" class="pb-directory-numeric">Forum posts</th>
            </tr>
          </thead>
          <tbody :for={site <- @page.sites} id={"directory-" <> site.host}>
            <tr class="pb-directory-row">
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
                    <button
                      :if={@page.cache_available? and site.due? and !site.pending?}
                      type="button"
                      class="pb-directory-refresh"
                      phx-click="update"
                      phx-value-host={site.host}
                      phx-disable-with="…"
                      aria-label={"Refresh " <> site.name}
                      title="Refresh tools"
                    >
                      <.refresh_icon />
                    </button>
                    <span
                      :if={site.pending?}
                      class="pb-directory-refresh pb-directory-refresh--busy"
                      role="status"
                      aria-label={"Refreshing " <> site.name}
                    >
                      <.refresh_icon /><span class="visually-hidden">Refreshing</span>
                    </span>
                    <span
                      :if={site.failed? and !site.pending?}
                      class="pb-directory-failure"
                      role="status"
                    >Check incomplete</span>
                  </div>
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
                  <span>{if site.source == "Source scan", do: "Detected", else: "Reported"}</span>
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
            <tr
              id={"tools-" <> site.host}
              class="pb-directory-detail"
              hidden={!MapSet.member?(@expanded, site.host)}
            >
              <td colspan="3">
                <div class="pb-directory-detail-inner">
                  <div class="pb-directory-detail-heading">
                    <span><strong>{site.name}</strong> · {site.category}</span>
                    <a href={"/" <> site.domain}>Open forum →</a>
                  </div>
                  <p :if={site.reported_observation} class="pb-directory-evidence">
                    CSV report: {site.reported_observation["count"]} tools · {site.reported_observation[
                      "source"
                    ]}
                    <span :if={site.reported_observation["snapshot_date"]}> · {site.reported_observation["snapshot_date"]}</span>.
                    Site-wide report; not a simultaneous homepage count.
                  </p>
                  <p :if={site.failed?} class="pb-directory-notice">
                    The check was incomplete. Previous information is kept.
                  </p>
                  <ul
                    :if={site.tools != []}
                    class="pb-directory-tool-list"
                    tabindex="0"
                    aria-label={"Recorded WebMCP tools for " <> site.name}
                  >
                    <li :for={tool <- site.tools}>
                      <code>{tool["name"]}</code><span>{URI.parse(tool["address"]).path || "/"}</span>
                    </li>
                  </ul>
                  <p :if={site.tools == []} class="pb-directory-empty">
                    {if site.source == "Source scan",
                      do:
                        "No tools detected in the page source. Browser-only tools may still be available.",
                      else: "Tool names have not been recorded for this listing."}
                  </p>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@page.sites == []} class="pb-directory-empty">
        No matching sites. Try another name or category.
      </p>
      <p class="pb-directory-key">
        — Not reported. Forum posts count public threads across the domain, including subdomains.
      </p>
      <nav :if={@page.pages > 1} class="pb-directory-pagination" aria-label="Directory pages">
        <a
          :if={@page.page > 1}
          class="rg-button rg-button--secondary"
          href={SiteDirectory.page_url(@page, @page.page - 1)}
        >← Previous</a>
        <span>{@page.page} / {@page.pages}</span>
        <a
          :if={@page.page < @page.pages}
          class="rg-button rg-button--secondary"
          href={SiteDirectory.page_url(@page, @page.page + 1)}
        >Next →</a>
      </nav>
      <details class="pb-directory-method">
        <summary>About the data</summary>
        <p>
          Reported tool counts come from the supplied research, CSV and public directory snapshots. They can differ from the number of recorded tool names. Older CSV counts do not replace newer inventories.
        </p>
        <p>
          Refresh is available every 24 hours. It reads public pages and scripts without signing in or calling tools. It can miss browser-only tools. Sites sharing a domain share a check; failed checks keep previous information.
        </p>
        <p>
          Forum posts are all-time published threads, excluding replies and hidden posts; a dash means the count could not be read.
        </p>
      </details>
    </section>
    """
  end

  defp refresh_icon(assigns) do
    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8M21 3v5h-5" />
    </svg>
    """
  end

  defp initial(name), do: name |> String.first() |> String.upcase()
  defp metric(nil), do: "—"
  defp metric(number), do: to_string(number)
end
