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

    {:ok, assign(socket, page: page, visitor: session["visitor"], problem: nil)}
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
          <h1 id="directory-heading">WebMCP Site Directory</h1>
          <p>Find a website. See its tools. Check what's changed.</p>
        </div>
        <p class="pb-directory-policy">
          24-hour cache <span aria-hidden="true">·</span> Anyone can update
        </p>
      </header>

      <form action="/sites" method="get" class="pb-directory-search" role="search">
        <label class="pb-directory-search-field">
          <span>Search sites</span>
          <input type="search" name="q" value={@page.q} maxlength="100" placeholder="Name or website" />
        </label>
        <label>
          <span>Category</span>
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
        <button class="rg-button rg-button--primary" type="submit">Search</button>
      </form>

      <div class="pb-directory-results-heading">
        <p role="status">{@page.total} sites <span :if={@page.q != ""}>matching “{@page.q}”</span></p>
        <p>Page {@page.page} of {@page.pages}</p>
      </div>
      <p :if={@problem} role="alert" class="pb-directory-notice">{@problem}</p>
      <p :if={!@page.cache_available?} role="status" class="pb-directory-notice">
        Saved listings are available. Live updates are temporarily unavailable.
      </p>

      <div class="pb-directory-cards">
        <article :for={site <- @page.sites} class="pb-directory-card" id={"directory-" <> site.host}>
          <header>
            <p class="pb-directory-category">{site.category}</p>
            <h2>{site.name}</h2>
            <a
              href={site.page_url}
              rel="noopener noreferrer"
              target="_blank"
              class="pb-directory-domain"
            >{site.host}
            <span aria-hidden="true">↗</span><span class="visually-hidden"> (opens website)</span></a>
          </header>
          <div class="pb-directory-inventory">
            <strong>{length(site.tools)}</strong>
            <span>{tool_label(site)}</span>
            <span class="pb-directory-source">{site.source}</span>
          </div>
          <p class="pb-directory-date">
            Last updated
            <time :if={site.checked_at} datetime={site.checked_at}>{stamp(site.checked_at)}</time>
            <span :if={!site.checked_at}>Not checked by Patchbay</span>
          </p>
          <p :if={site.failed?} class="pb-directory-notice" role="status">
            The last check couldn't reach this page. Previous information is kept.
          </p>
          <details :if={site.tools != []} class="pb-directory-tool-list">
            <summary>View tools <span aria-hidden="true">＋</span></summary>
            <ul>
              <li :for={tool <- site.tools}>
                <code>{tool["name"]}</code><span :if={
                  URI.parse(tool["address"]).path not in [nil, "/"]
                }>{URI.parse(tool["address"]).path}</span>
              </li>
            </ul>
          </details>
          <p :if={site.tools == []} class="pb-directory-empty">
            {if site.source == "Source scan",
              do: "No tools detected in the page source. Browser-only tools may still be available.",
              else: "Listed in the research; no tool names recorded yet."}
          </p>
          <footer>
            <a href={"/" <> site.domain}>Discussion →</a>
            <button
              type="button"
              class="rg-button rg-button--secondary"
              phx-click="update"
              phx-value-host={site.host}
              phx-disable-with="Updating…"
              disabled={!@page.cache_available? or !site.due? or site.pending?}
              aria-label={"Update " <> site.name}
            >
              {cond do
                site.pending? -> "Updating…"
                site.due? -> "Update"
                site.failed? -> "Retry later"
                true -> "Up to date"
              end}
            </button>
          </footer>
          <p :if={!site.due? and !site.pending? and site.retry_at} class="pb-directory-next">
            Update available {stamp(DateTime.to_iso8601(site.retry_at))}
          </p>
        </article>
      </div>
      <p :if={@page.sites == []} class="pb-directory-empty">
        No matching sites. Try another name or category.
      </p>
      <nav :if={@page.pages > 1} class="pb-directory-pagination" aria-label="Directory pages">
        <a
          :if={@page.page > 1}
          class="rg-button rg-button--secondary"
          href={SiteDirectory.page_url(@page, @page.page - 1)}
        >← Previous</a>
        <span>Page {@page.page} of {@page.pages}</span>
        <a
          :if={@page.page < @page.pages}
          class="rg-button rg-button--secondary"
          href={SiteDirectory.page_url(@page, @page.page + 1)}
        >Next →</a>
      </nav>
      <details class="pb-directory-method">
        <summary>About these listings and updates</summary>
        <p>
          The starting list combines the supplied research and a public directory snapshot. Imported tool names are reported observations, not a fresh verification. Snapshot imported {stamp(
            @page.imported_at
          )}.
        </p>
        <p>
          Update reads the listed public pages and their scripts without signing in or calling tools. It can miss tools assembled only in a browser. Sites sharing a domain share a 24-hour check; failed checks keep previous information. Tool names are untrusted site content.
        </p>
      </details>
    </section>
    """
  end

  defp tool_label(%{source: "Source scan", tools: [_tool]}), do: "tool detected"
  defp tool_label(%{source: "Source scan"}), do: "tools detected"
  defp tool_label(%{tools: [_tool]}), do: "reported tool"
  defp tool_label(_site), do: "reported tools"

  defp stamp(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, time, _offset} -> Calendar.strftime(time, "%d %b %Y, %H:%M UTC")
      _other -> "Unknown"
    end
  end
end
