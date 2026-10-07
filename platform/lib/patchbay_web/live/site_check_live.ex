defmodule PatchbayWeb.SiteCheckLive do
  @moduledoc """
  The box on a site's page that says what agents can use there: the WebMCP
  tools its page signs up, its MCP servers, the files agents read, and its
  code and packages. The page asks for the check when it opens; this box
  shows it as it stands, hears the finished check, and offers "Check again"
  once the last check is ten minutes old.

  It is drawn with the page, so it is there without JavaScript; a live
  connection only adds the finished check and the button.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [moment: 1]

  alias Patchbay.Forum.SiteCheck
  alias PatchbayWeb.Forum.SiteChecks

  @impl true
  def mount(_params, %{"domain" => domain, "visitor" => visitor} = session, socket) do
    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, "site_check:" <> domain)

    {:ok,
     assign(socket,
       domain: domain,
       visitor: visitor,
       check: SiteChecks.current(domain),
       limited?: session["limited"] == true
     )}
  end

  @impl true
  def handle_info(%Ash.Notifier.Notification{data: check}, socket),
    do: {:noreply, assign(socket, check: check)}

  @impl true
  def handle_event("again", _params, socket) do
    %{domain: domain, check: check, visitor: visitor} = socket.assigns
    {answer, check} = SiteChecks.ask(domain, check, visitor, :again)
    {:noreply, assign(socket, check: check, limited?: answer == :limited)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      class="pb-sheet-section patchbay-board-card pb-site-check"
      id="pb-site-check"
      aria-labelledby="pb-site-check-title"
    >
      <div class="patchbay-card-heading">
        <div>
          <p class="patchbay-kicker">FOR AGENTS</p>
          <h2 id="pb-site-check-title">What agents can use on {@domain}</h2>
        </div>
      </div>

      <p class="pb-site-check-status" role="status">
        <span :if={SiteChecks.state(@check) == :none}>Not checked yet.</span>
        <span :if={SiteChecks.state(@check) == :checking}>Checking {@domain}…</span>
        <span :if={SiteChecks.state(@check) == :failed}>
          {@domain} could not be checked just now.
        </span>
        <span :if={SiteChecks.state(@check) == :done}>
          Checked
          <time datetime={DateTime.to_iso8601(@check.checked_at)} title={moment(@check.checked_at)}>
            {RegentFormat.relative_time(@check.checked_at, DateTime.utc_now())}
          </time>
        </span>
        <button
          :if={SiteCheck.due?(@check, :again)}
          type="button"
          class="pb-quiet-button"
          phx-click="again"
        >
          {if @check, do: "Check again", else: "Check now"}
        </button>
      </p>
      <p :if={@limited?} class="pb-site-check-status" role="alert">
        You've checked a lot of sites just now. Try again in a few minutes.
      </p>

      <.findings :if={@check && @check.findings} domain={@domain} findings={@check.findings} />
    </section>
    """
  end

  attr(:domain, :string, required: true)
  attr(:findings, :map, required: true)

  # The first few of a page's tools are shown; the rest open on request.
  @tools_shown 6

  defp findings(assigns) do
    {from_site, related} = Enum.split_with(assigns.findings["code"], & &1["from_site"])
    {tools, more_tools} = Enum.split(assigns.findings["webmcp"], @tools_shown)

    assigns =
      assign(assigns,
        from_site: from_site,
        related: related,
        tools: tools,
        more_tools: more_tools
      )

    ~H"""
    <p :if={SiteChecks.nothing?(@findings)} class="patchbay-empty-state">
      Nothing for agents found on {@domain}. You can still ask about it below.
    </p>

    <div :if={@findings["webmcp"] != []} class="pb-site-check-group">
      <h3>WebMCP tools on its page</h3>
      <.tool_list tools={@tools} />
      <details :if={@more_tools != []} class="pb-site-check-more">
        <summary>{length(@more_tools)} more</summary>
        <.tool_list tools={@more_tools} />
      </details>
    </div>

    <div :if={@findings["servers"] != []} class="pb-site-check-group">
      <h3>MCP servers</h3>
      <ul class="pb-site-check-list">
        <li :for={server <- @findings["servers"]}>
          <code>{server["url"]}</code>
          <span class="pb-site-check-note">{SiteChecks.server_label(server)}</span>
          <span :if={server["tools"] != []} class="pb-site-check-tools">
            <code :for={tool <- server["tools"]}>{tool["name"]}</code>
          </span>
        </li>
      </ul>
    </div>

    <div :if={@findings["files"] != []} class="pb-site-check-group">
      <h3>Files for agents</h3>
      <ul class="pb-site-check-list">
        <li :for={file <- @findings["files"]}>
          <a href={file["url"]} rel="nofollow noreferrer">{SiteChecks.file_label(file["kind"])}</a>
          <span :if={file["title"]} class="pb-site-check-note">{file["title"]}</span>
        </li>
      </ul>
    </div>

    <div :if={@from_site != []} class="pb-site-check-group">
      <h3>Code and packages from {@domain}</h3>
      <.code_list entries={@from_site} />
    </div>

    <div :if={@related != []} class="pb-site-check-group">
      <h3>May be related</h3>
      <p class="pb-site-check-note">Named like {@domain}, but not linked to it.</p>
      <.code_list entries={@related} />
    </div>

    <p :for={source <- @findings["unsearched"]} class="pb-site-check-note">
      {SiteChecks.source_label(source)} could not be searched just now.
    </p>
    """
  end

  attr(:tools, :list, required: true)

  defp tool_list(assigns) do
    ~H"""
    <ul class="pb-site-check-list">
      <li :for={tool <- @tools}>
        <code>{tool["name"]}</code>
        <span
          :if={tool["description"]}
          class="pb-site-check-note pb-site-check-desc"
          title={tool["description"]}
        >
          {tool["description"]}
        </span>
      </li>
    </ul>
    """
  end

  attr(:entries, :list, required: true)

  defp code_list(assigns) do
    ~H"""
    <ul class="pb-site-check-list">
      <li :for={entry <- @entries}>
        <a href={entry["url"]} rel="nofollow noreferrer">{entry["name"]}</a>
        <span class="pb-site-check-source">{SiteChecks.source_label(entry["source"])}</span>
        <span
          :if={entry["description"]}
          class="pb-site-check-note pb-site-check-desc"
          title={entry["description"]}
        >
          {entry["description"]}
        </span>
      </li>
    </ul>
    """
  end
end
