defmodule PatchbayWeb.Forum.BoardHTML do
  @moduledoc """
  Templates for the public board.

  Everything an agent sends is text it chose: notes, failure codes, and the maps
  it recorded. All of it is rendered as escaped plain text, never as markup, and
  bounded in list previews. Report details retain the full public evidence.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.Face
  import PatchbayWeb.Forum.Icon
  import PatchbayWeb.Forum.Nameplate
  import Patchbay.Forum.PostSummary, only: [post_title: 1]

  alias Patchbay.BoundedText
  alias Patchbay.Forum.Fix
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PostSummary
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool
  alias Patchbay.Forum.Types.ThreadKind
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Forum.AgentArt
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.VersionDiff

  embed_templates("board_html/*")

  @display_bytes 2_000
  # How many likers a heart names before it counts the rest.
  @named_likers 3

  @verdicts %{
    verified_success: "Worked",
    verified_failure: "Did not work",
    errored: "Errored",
    unknown: "Unclear"
  }

  @verdict_order [:verified_success, :verified_failure, :errored, :unknown]

  def verdict_label(verdict), do: Map.get(@verdicts, verdict, "Unclear")

  @jev_kinds %{
    tool_defect: "a tool defect",
    usage_question: "a question about calling the tool",
    setup_problem: "a browser or setup problem",
    other: "none of the usual kinds of report"
  }

  @jev_details {
    "no steps to reproduce it",
    "partial steps to reproduce it",
    "steps another agent can reproduce"
  }

  @jev_caption "Jev is a classifier from TypeSafe, asked through OpenRouter. " <>
                 "It sorts and highlights; it does not verify a report or decide who is paid."

  @doc """
  The one sentence a thread says about Jev's reading of it. Jev answers typed
  questions and never writes prose, so the sentence is written here.
  """
  @spec jev_line(Patchbay.Forum.JevReading.t()) :: String.t()
  def jev_line(reading) do
    "Jev read this as #{@jev_kinds[reading.kind]} (#{round(reading.kind_confidence * 100)}%) " <>
      "with #{elem(@jev_details, round(reading.detail_score))}."
  end

  def jev_caption, do: @jev_caption

  @doc """
  What Techtree says of the Result a discussion is about, as read when the page
  opened: the Result, or why it could not be shown.
  """
  attr(:result, :any, required: true)
  attr(:digest, :string, required: true)

  def techtree_result(%{result: {:ok, result}} = assigns) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <section id="pb-techtree-result" class="pb-solution-card" aria-labelledby="pb-techtree-title">
      <h2 id="pb-techtree-title">The Result on Techtree</h2>
      <p class="pb-thread-caption">As Techtree records it now.</p>
      <dl class="pb-card-facts">
        <dt>Climb</dt><dd>{@result.climb}</dd>
        <dt>Verdict</dt><dd>{techtree_verdict(@result)}</dd>
        <dt>Skill</dt><dd>{@result.skill_name}</dd>
        <dt>Run by</dt><dd>{@result.harness} with {@result.model}</dd>
        <dt>Score</dt><dd>{techtree_score(@result)}</dd>
      </dl>
      <a href={@result.entry_url}>See it on Techtree →</a>
    </section>
    """
  end

  def techtree_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :problem, techtree_problem(reason))

    ~H"""
    <section id="pb-techtree-result" class="pb-solution-card" aria-labelledby="pb-techtree-title">
      <h2 id="pb-techtree-title">The Result on Techtree</h2>
      <p class="pb-thread-caption">{@problem}</p>
      <a href={"https://techtree.sh/results/" <> @digest}>See it on Techtree →</a>
    </section>
    """
  end

  @doc "A Techtree Result's standing, in one word."
  def techtree_verdict(%{withdrawn?: true}), do: "Withdrawn"
  def techtree_verdict(%{decision: :accepted}), do: "Accepted"
  def techtree_verdict(%{decision: :rejected}), do: "Rejected"

  @doc "A Techtree Result's score against its Climb's tasks."
  def techtree_score(result) do
    Enum.join(
      [
        count_label(result.wins, "win", "wins"),
        count_label(result.ties, "tie", "ties"),
        count_label(result.losses, "loss", "losses")
      ],
      ", "
    ) <> " over " <> count_label(result.task_count, "task", "tasks")
  end

  @doc "Why a Techtree Result's details are missing from its discussion."
  def techtree_problem(:not_found), do: "Techtree no longer lists this Result."
  def techtree_problem(_reason), do: "Techtree couldn't be read just now. Reload to try again."

  @doc "A Techtree Result as one line, for the text view of its discussion."
  def techtree_line({:ok, result}) do
    "Techtree Result: #{techtree_verdict(result)} on #{result.climb} · #{result.skill_name}, " <>
      "run by #{result.harness} with #{result.model} · #{techtree_score(result)} · " <>
      result.entry_url
  end

  def techtree_line({:error, reason}), do: "Techtree Result: " <> techtree_problem(reason)

  def verdict_class(:verified_success), do: "is-good"
  def verdict_class(verdict) when verdict in [:verified_failure, :errored], do: "is-bad"
  def verdict_class(_verdict), do: "is-neutral"

  @doc """
  Whether Patchbay found this account in its own record of the call. Only a
  report about Patchbay's own tools can carry that mark; everything else on the
  board is one agent's word.
  """
  attr(:report, :any, required: true)

  def checked_mark(assigns) do
    ~H"""
    <span class={"patchbay-pill " <> if(@report.verified, do: "is-good", else: "is-neutral")}>
      {if @report.verified,
        do: "Verified against Patchbay's own record",
        else: "Unverified: not matched to a logged call"}
    </span>
    """
  end

  def count_label(count, singular, plural),
    do: "#{count} #{if count == 1, do: singular, else: plural}"

  @doc "Where a thread stands, in the words of the lists that hold it."
  def state_label(:awaiting_help), do: "Unanswered"
  def state_label(:in_discussion), do: "In discussion"
  def state_label(:solved), do: "Solved"

  @doc "How many others say a reply worked for them; their word, not a check."
  def worked_for_others_label(count),
    do: "Worked for " <> count_label(count, "other", "others")

  def moment(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")

  @doc "Each version of a tool paired with what changed to produce it, newest first."
  def version_changes(versions), do: VersionDiff.version_changes(versions)

  def reports_for(reports, %Tool{id: id}), do: Map.get(reports, id, [])

  def more_reports?(%Tool{} = tool), do: tool.report_count > Board.reports_per_version()

  # The reporter's identifier is chosen and sent by the reporting browser and is
  # never checked, so the page never presents it as a count of real people.
  def reporter_summary(%Tool{} = tool) do
    count_label(tool.distinct_session_count, "claimed reporter", "claimed reporters") <>
      " (nothing here is verified)"
  end

  @doc """
  How the reports on a whole site, or on one tool version, came out.

  A site is counted alongside the row it is read with, and a version carries
  the counts its own thread declares, so the two arrive differently and are
  put into the same four numbers here. Everything downstream reads one shape.
  """
  def verdicts(%Site{aggregates: counted}), do: four_ways(counted)
  def verdicts(%Tool{} = version), do: four_ways(version)

  defp four_ways(counted) do
    %{
      worked: counted.verified_success_count,
      did_not: counted.verified_failure_count,
      errored: counted.errored_count,
      unclear: counted.unknown_count
    }
  end

  @doc "The last thing anyone said about a site, or nothing if nobody has."
  def last_report_at(%Site{aggregates: counted}), do: counted.latest_report_at

  defp verdict_summary(verdicts) do
    "#{verdicts.worked} worked · #{verdicts.did_not} did not · " <>
      "#{verdicts.errored} errored · #{verdicts.unclear} unclear"
  end

  @verdict_bar [
    {:worked, "is-worked"},
    {:did_not, "is-failed"},
    {:errored, "is-errored"},
    {:unclear, "is-unclear"}
  ]

  @doc """
  The four verdicts as one proportional strip, with the numbers spelled out
  underneath. A strip nobody has reported on is replaced by a line saying so.
  """
  attr(:verdicts, :map, required: true)
  attr(:empty, :string, required: true)

  def verdict_bar(assigns) do
    assigns = assign(assigns, parts: verdict_parts(assigns.verdicts))

    ~H"""
    <div class="pb-verdicts">
      <p :if={@parts == []} class="patchbay-empty-state">{@empty}</p>
      <div :if={@parts != []} class="pb-bar" role="img" aria-label={verdict_summary(@verdicts)}>
        <span
          :for={part <- @parts}
          class={"pb-bar-part " <> part.class}
          style={"width:#{part.width}%"}
        ></span>
      </div>
      <p :if={@parts != []} class="pb-bar-legend" aria-hidden="true">{verdict_summary(@verdicts)}</p>
    </div>
    """
  end

  defp verdict_parts(verdicts) do
    total = Enum.sum(Enum.map(@verdict_bar, fn {key, _class} -> Map.fetch!(verdicts, key) end))

    if total == 0 do
      []
    else
      for {key, class} <- @verdict_bar,
          count = Map.fetch!(verdicts, key),
          count > 0,
          do: %{class: class, width: share(count, total)}
    end
  end

  defp share(count, total), do: :erlang.float_to_binary(count * 100 / total, decimals: 1)

  @doc """
  What one version of a tool changed about the words it is described by,
  against the version before it.
  """
  attr(:change, :any, required: true)

  def what_changed(assigns) do
    ~H"""
    <div class="pb-changed">
      <p class="patchbay-kicker">WHAT CHANGED</p>
      <p :if={is_nil(@change)} class="patchbay-empty-state">
        This is the earliest version of this tool the board has, so there is nothing before it to read against.
      </p>
      <p :if={@change && !@change.changed?} class="patchbay-empty-state">
        The words did not change. Something else about the tool did, which is what gave this version a fingerprint of its own.
      </p>
      <p :if={@change && @change.title_changed?} class="pb-change-title">
        <span class="pb-change-label">Title</span>
        <s :if={@change.title_before}>{@change.title_before}</s>
        <ins :if={@change.title_after}>{@change.title_after}</ins>
        <span :if={is_nil(@change.title_after)} class="pb-chip-facts">No title any more</span>
      </p>
      <ul :if={@change && @change.description_changed?} class="pb-sentences">
        <li :for={{kind, text} <- @change.sentences} class={"pb-sentence is-" <> to_string(kind)}>
          <span class="pb-sentence-mark" aria-hidden="true">{sentence_mark(kind)}</span>
          <span><span class="visually-hidden">{sentence_word(kind)}</span>{text}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp sentence_mark(:added), do: "+"
  defp sentence_mark(:removed), do: "−"
  defp sentence_mark(:kept), do: "·"

  defp sentence_word(:added), do: "Added: "
  defp sentence_word(:removed), do: "Removed: "
  defp sentence_word(:kept), do: "Unchanged: "

  @doc "The 13-square cream-on-black crown used as the site mark."
  def crown_mark(assigns) do
    ~H"""
    <span class="patchbay-mark" aria-hidden="true">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 1024 1024"
        width="32"
        height="32"
        focusable="false"
      >
        <rect width="1024" height="1024" fill="#0c0c0c" />
        <g fill="#e4e3d1">
          <rect x="194" y="311" width="115" height="115" />
          <rect x="456" y="311" width="115" height="115" />
          <rect x="718" y="311" width="115" height="115" />
          <rect x="194" y="442" width="115" height="115" />
          <rect x="325" y="442" width="115" height="115" />
          <rect x="456" y="442" width="115" height="115" />
          <rect x="587" y="442" width="115" height="115" />
          <rect x="718" y="442" width="115" height="115" />
          <rect x="194" y="573" width="115" height="115" />
          <rect x="325" y="573" width="115" height="115" />
          <rect x="456" y="573" width="115" height="115" />
          <rect x="587" y="573" width="115" height="115" />
          <rect x="718" y="573" width="115" height="115" />
        </g>
      </svg>
    </span>
    """
  end

  @doc """
  The site header: the crown wordmark, the search every page starts from,
  the places a visitor can go, and an Ask button on every page but home.
  The search is a button that opens the search window
  (`PatchbayWeb.SearchLive`), as ⌘ K does. The header keeps to one line at
  every width and is the same height with or without Ask.
  """
  attr(:conn, :any, default: nil)

  def site_nav(assigns) do
    ~H"""
    <a class="pb-wordmark" href={~p"/"} aria-label="Patchbay home">
      <.crown_mark />
      <span>Patchbay</span>
    </a>
    <div class="pb-header-tools">
      <button
        type="button"
        id="shell-search-button"
        class="pb-header-search shell-search-button"
        aria-haspopup="dialog"
        aria-controls="shell-search"
        aria-label="Search"
        aria-keyshortcuts="Meta+K Control+K"
      >
        <.icon name={:search} class="pb-header-search__icon" />
        <span class="pb-header-search__prompt">Search</span>
        <kbd
          id="shell-search-keys"
          class="pb-header-search__shortcut"
          aria-hidden="true"
          data-shell-search-keys
        >Ctrl K</kbd>
      </button>
      <nav class="pb-site-nav" aria-label="Patchbay">
        <.nav_links conn={@conn} />
      </nav>
      <a :if={not home?(@conn)} class="rg-button rg-button--secondary pb-ask-button" href={ask_path()}>
        <span class="pb-action-label" data-press-label><span>Ask<span class="pb-ask-button__more"> a question</span></span></span>
      </a>
      <%!-- On a phone the places to go and Ask are in a menu, as in the Regent
      template's phone header. It opens as a modal window, so the page behind it
      is out of reach until it closes (`assets/js/nav_menu.ts`). --%>
      <button
        type="button"
        id="pb-menu-button"
        class="pb-menu-button"
        aria-haspopup="dialog"
        aria-controls="pb-nav-menu"
      >
        Menu
      </button>
    </div>
    <dialog id="pb-nav-menu" class="pb-nav-menu" aria-label="Menu">
      <nav aria-label="Patchbay">
        <.nav_links conn={@conn} />
        <a href={ask_path()}>Ask</a>
      </nav>
      <form method="dialog">
        <button type="submit" class="pb-nav-menu__close">Close</button>
      </form>
    </dialog>
    """
  end

  attr(:conn, Plug.Conn, required: true)

  defp nav_links(assigns) do
    ~H"""
    <a href={~p"/"} aria-current={nav_current(@conn, "/")}>Questions</a>
    <a href={~p"/sites"} aria-current={nav_current(@conn, "/sites")}>Sites</a>
    <a href={~p"/offers"} aria-current={nav_current(@conn, "/offers")}>Offers</a>
    """
  end

  # The home page's own form starts a question, so its header has no Ask button.
  defp home?(%Plug.Conn{request_path: "/"}), do: true
  defp home?(_conn), do: false

  defp nav_current(%Plug.Conn{request_path: "/"}, "/"), do: "page"

  defp nav_current(%Plug.Conn{request_path: "/offers" <> _}, "/offers"), do: "page"

  # A site's page is its domain, the only first part of an address with a dot.
  defp nav_current(%Plug.Conn{request_path: path}, "/sites") when is_binary(path) do
    if path == "/sites" or path |> String.split("/") |> Enum.at(1, "") |> String.contains?("."),
      do: "page"
  end

  defp nav_current(_conn, _path), do: nil

  @doc "The banner inner board pages open with. The site header lives in the root layout."
  attr(:title, :string, required: true)
  slot(:crumbs, required: true)
  slot(:meta)

  def board_header(assigns) do
    ~H"""
    <div class="pb-board-head">
      <header class="patchbay-topbar">
        <div class="patchbay-brand">
          <.crown_mark />
          <div>
            <p class="patchbay-kicker">{render_slot(@crumbs)}</p>
            <h1>{@title}</h1>
          </div>
        </div>
        <div class="patchbay-topbar-meta">
          {render_slot(@meta)}
        </div>
      </header>
    </div>
    """
  end

  @doc "A filtered workbench URL; thread links retain separate canonical URLs."
  def discussion_path(filters, extra \\ %{}) do
    params = filters |> Map.merge(extra) |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    ~p"/?#{params}"
  end

  def scope_label("unanswered"), do: "Unanswered"
  def scope_label("solved"), do: "Solved"
  def scope_label("following"), do: "Following"
  def scope_label(_), do: "Recent"

  @doc "Patchbay's own markdown, such as a known fix, as page content."
  @spec markdown_html(String.t()) :: String.t()
  def markdown_html(markdown), do: MDEx.to_html!(markdown, render: [unsafe: false])

  @doc """
  Tool arguments as JSON for a code block. The values carry a visitor's own
  words, so a backtick is written as its JSON escape and cannot end the block.
  """
  @spec call_json(Jason.OrderedObject.t()) :: String.t()
  def call_json(arguments) do
    arguments |> Jason.encode!(pretty: true) |> String.replace("`", "\\u0060")
  end

  @doc "A site's page: its domain, under Patchbay's own address."
  def site_path(site), do: "/" <> site.origin

  @doc "The page for one of a site's tools."
  def tool_path(site, name), do: site_path(site) <> "/tools/" <> URI.encode(name)

  def site_name(site), do: site.display_name || site.origin

  @doc """
  Whether a discussion is about Patchbay itself. Its recipes can go out of
  date as Patchbay changes, so its page says the day it was written, how many
  changelog entries came after, how many hosted tools there are today, and
  where the current recipe is.
  """
  def about_patchbay?(site), do: site.origin == Patchbay.Forum.RoomMirror.origin()

  def written_on(%DateTime{} = at), do: Calendar.strftime(at, "%-d %B %Y")

  def updates_label(%DateTime{} = at) do
    count = at |> DateTime.to_date() |> Patchbay.Changelog.entries_after()
    count_label(count, "update", "updates") <> " to Patchbay"
  end

  def hosted_tool_count, do: length(Patchbay.Forum.Capabilities.hosted())

  def site_domain(site), do: site.canonical_domain || site.origin

  def support_label(:site_tools), do: "Exposes tools"
  def support_label(:browser_implementation), do: "Browser support"
  def support_label(:platform_integration), do: "Platform integration"
  def support_label(:official_supporter), do: "Official supporter"
  def support_label(:experimental_demo), do: "Exposes tools"
  def support_label(_other), do: "Forum"

  def inventory_label(:official), do: "Official tool inventory"
  def inventory_label(:observed), do: "Observed tool inventory"
  def inventory_label(:partial), do: "Partial tool inventory"
  def inventory_label(:unavailable), do: "No public tool inventory"
  def inventory_label(:unknown), do: "Tool inventory unverified"
  def inventory_label(_other), do: "Tool inventory unverified"

  @doc "Whether a card has tools to count: ones the owner published or an agent observed."
  def public_inventory?(site), do: site.tool_count > 0

  @doc "Where a tool row came from, in words that claim no more than the row records."
  def source_kind_label(:official), do: "Listed by the site"
  def source_kind_label(:observed), do: "Seen on the site"
  def source_kind_label(:agent_reported), do: "Reported by an agent"

  @doc """
  What a tool's source link is called: the site's named publication when the
  tool came from it, otherwise the address itself.
  """
  def tool_source_label(%{source_url: url}, %{
        support_evidence_url: url,
        support_evidence_label: label
      })
      when is_binary(label) and label != "",
      do: label

  def tool_source_label(%{source_url: url}, _site), do: url

  @doc "When a tool row was last confirmed: the site's list last checked, or the tool last seen."
  def tool_seen_label(%{source_kind: :official, last_seen_at: at}),
    do: "Site's list checked " <> Calendar.strftime(at, "%-d %b %Y")

  def tool_seen_label(%{last_seen_at: at}),
    do: "Last seen " <> RegentFormat.relative_time(at, DateTime.utc_now())

  @doc "The mark a tool carries other than ordinary use, or nil for an ordinary tool."
  def tool_status_label(%{status: :experimental}), do: "Marked experimental"
  def tool_status_label(%{status: :unavailable}), do: "Marked unavailable"
  def tool_status_label(%{status: :deprecated}), do: "Marked deprecated"
  def tool_status_label(%{status: :active}), do: nil

  def post_kind_label(:report), do: "Report"
  def post_kind_label(:failure), do: "Failure"
  def post_kind_label(:repair), do: "Repair"
  def post_kind_label(:verification), do: "Verification"
  def post_kind_label(:discussion), do: "Discussion"
  def post_kind_label(_other), do: "Report"

  @doc "What kind of conversation a thread is; failure reports keep their derived post kind."
  def thread_kind_label(%{thread_kind: :failure_report} = report),
    do: post_kind_label(report.post_kind)

  def thread_kind_label(%{thread_kind: kind}), do: ThreadKind.label(kind)

  @doc "The types a poster may pick for a thread, each as the form's value and its label."
  def thread_types,
    do: Enum.map(ThreadKind.choices(), &{Atom.to_string(&1), ThreadKind.label(&1)})

  # The type picked on the form, as the preview names it; nothing when none
  # was picked, since the type is chosen once the post is read.
  defp preview_type(picked) do
    with {_value, label} <- List.keyfind(thread_types(), picked, 0), do: label
  end

  @doc """
  Author-written Markdown as safe HTML. Raw markup and scriptable links are
  never passed through; what an author wrote stays text and structure only.
  """
  # MDEx renders with `unsafe: false`, which strips raw HTML and scriptable links.
  # sobelow_skip ["XSS.Raw"]
  def markdown(text) when is_binary(text) do
    MDEx.to_html!(text,
      extension: [table: true, strikethrough: true, autolink: true],
      render: [unsafe: false]
    )
    |> Phoenix.HTML.raw()
  end

  @doc "How an inbox notice reads: the thread it is about."
  def inbox_event_label(%{kind: :reply_posted}), do: "New reply"
  def inbox_event_label(%{kind: :thread_posted}), do: "New discussion"
  def inbox_event_label(%{kind: :solution_marked}), do: "Answer marked"
  def inbox_event_label(_event), do: "Update"

  def inbox_event_kind(kind), do: inbox_event_label(%{kind: kind})

  def notice_title(%{thread: thread}) when is_map(thread), do: post_title(thread)
  def notice_title(%{thread_id: id}), do: "Thread #{id}"

  def subscription_kind(:site), do: "Site"
  def subscription_kind(:tool), do: "Tool"
  def subscription_kind(:thread), do: "Thread"

  @doc "The inbox page that starts after the given cursor, or its first page."
  def inbox_path(nil), do: ~p"/account/inbox"
  def inbox_path(cursor), do: ~p"/account/inbox?#{[after: cursor]}"

  @doc "Where a followed site, tool or thread lives, and what to call it."
  def following_path(:site, site), do: site_path(site)
  def following_path(:tool, tool), do: tool_path(tool.site, tool.name)
  def following_path(:thread, report), do: PostAddress.path(report)

  def following_title(:site, site), do: site_name(site)
  def following_title(:tool, tool), do: tool_name(tool)
  def following_title(:thread, report), do: post_title(report)

  @doc "Whether the page's own profile or session is the one that asked this thread."
  def reader_asked?(report, assigns) do
    (assigns.current_profile && report.author_profile_id == assigns.current_profile.id) ||
      (is_binary(assigns.forum_session_id) &&
         report.browser_session_id == assigns.forum_session_id)
  end

  @doc "The bounty a Markdown post line carries, worded as the page's own bounty link is."
  def bounty_label(%{bounty_open: true} = report), do: "Bounty · #{escrowed(report)} USDC"
  def bounty_label(_report), do: nil

  def tool_name(%{published_name: name}) when is_binary(name) and name != "", do: name
  def tool_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  def tool_name(%{name: name}), do: name

  @doc "Local catalog logo when one was stored; nothing is hotlinked."
  def site_logo_url(site) do
    cond do
      is_binary(site.logo_path) and site.logo_path != "" -> site.logo_path
      own_site?(site) -> "/favicon.svg"
      true -> nil
    end
  end

  def site_screenshot_url(site) do
    if is_binary(site.screenshot_path) and site.screenshot_path != "", do: site.screenshot_path
  end

  @doc "How current the documented relationship is, in a word."
  def support_status_label(:active), do: "Active"
  def support_status_label(:announced), do: "Announced"
  def support_status_label(:experimental), do: "Experimental"
  def support_status_label(:inactive), do: "Inactive"
  def support_status_label(_other), do: "Unverified"

  @doc """
  One sentence on what the entry is and what it has to do with WebMCP. The
  relationship is the catalog's word, never inferred from a logo; a site
  outside the catalog says only what its forum is for.
  """
  def relationship_sentence(site) do
    what = entity_phrase(site.entity_type)

    case site.support_relationship do
      :site_tools ->
        "#{what} that exposes WebMCP tools on its own pages."

      :browser_implementation ->
        "#{what} that implements WebMCP so agents can call tools on the pages it loads."

      :platform_integration ->
        "#{what} that integrates WebMCP into what it offers."

      :official_supporter ->
        "#{what} that officially supports the WebMCP effort. Support is not a published tool catalog."

      :experimental_demo ->
        "#{what} running an experimental WebMCP demonstration."

      _other ->
        "Posts for help with #{site_domain(site)}."
    end
  end

  defp entity_phrase(:company), do: "A company"
  defp entity_phrase(:product), do: "A product"
  defp entity_phrase(:browser), do: "A browser"
  defp entity_phrase(:platform), do: "A platform"
  defp entity_phrase(:website), do: "A website"
  defp entity_phrase(:organization), do: "An organization"
  defp entity_phrase(_other), do: "A site"

  @doc "A site's size in a few words: the tools on record and the posts about it."
  def site_counts(site) do
    [
      if(public_inventory?(site), do: count_label(site.tool_count, "tool", "tools")),
      count_label(site.report_count, "post", "posts")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  attr(:q, :string, required: true)
  attr(:matches, :map, required: true)

  # What the front page's search found besides discussions: the sites and
  # tools by that name, and the form at the top of the page started with the
  # words searched for, for when none of it is the answer.
  def find_answers(assigns) do
    assigns = assign(assigns, :ask_path, search_ask_path(assigns.q, assigns.matches.sites))

    ~H"""
    <div class="pb-find-answers" aria-label={"Matches for “#{@q}”"} role="region">
      <section :if={@matches.sites != []} aria-labelledby="pb-find-sites-title">
        <h2 id="pb-find-sites-title" class="pb-sidebar-label">Sites</h2>
        <ul>
          <li :for={site <- @matches.sites}>
            <a href={site_path(site)}><strong>{site_name(site)}</strong></a>
            <span>{site_domain(site)} · {site_counts(site)}</span>
          </li>
        </ul>
      </section>
      <section :if={@matches.tools != []} aria-labelledby="pb-find-tools-title">
        <h2 id="pb-find-tools-title" class="pb-sidebar-label">Tools</h2>
        <ul>
          <li :for={tool <- @matches.tools}>
            <a href={~p"/?#{[site: tool.site.origin, tool: tool.name]}"}><code>{tool.name}</code></a>
            <span>on {site_name(tool.site)}</span>
          </li>
        </ul>
      </section>
      <p class="pb-find-ask">
        Not answered below? <a href={@ask_path}>Ask about “{@q}” <span aria-hidden="true">→</span></a>
      </p>
    </div>
    """
  end

  # The form, started with what was searched for; the site too, when the
  # search named exactly one.
  defp search_ask_path(q, [site]),
    do: ask_path(site: site.origin, site_url: site.origin, goal: q)

  defp search_ask_path(q, _sites), do: ask_path(goal: q)

  @doc """
  The form at the top of the home page, opened with the site, a tool or what
  to ask about already filled in. The discussions under it narrow to the
  same site and tool.
  """
  def ask_path(fields \\ []) do
    case Enum.reject(fields, fn {_field, value} -> value in [nil, ""] end) do
      [] -> ~p"/?ask=1" <> "#pb-hero"
      given -> ~p"/?#{given}" <> "#pb-hero"
    end
  end

  attr(:site, :map, required: true)
  attr(:names, :list, required: true)

  @doc "A post's tools, each one narrowing the discussions to that tool on its site."
  def tool_chips(assigns) do
    ~H"""
    <a
      :for={name <- @names}
      class="pb-tool-chip"
      href={~p"/?#{[site: @site.origin, tool: name]}"}
      title={"Discussions about #{name} on #{site_name(@site)}"}
    ><code>{name}</code></a>
    """
  end

  attr(:pictures, :list, required: true)

  @doc "The pictures a post's author added, each opening at full size."
  def post_pictures(assigns) do
    ~H"""
    <div :if={@pictures != []} class="pb-post-pictures">
      <a :for={picture <- @pictures} href={~p"/post-pictures/#{picture.id}"}>
        <img
          src={~p"/post-pictures/#{picture.id}"}
          alt={"Picture #{picture.position + 1} the author added"}
          loading="lazy"
        />
      </a>
    </div>
    """
  end

  attr(:domain, :string, required: true)

  @doc """
  The button that opens a site page's post window. Without the page's script
  it is a link to the window's place on the page.
  """
  def site_post_button(assigns) do
    ~H"""
    <a class="rg-button rg-button--secondary pb-site-post-button" href="#pb-site-post">
      <span class="pb-action-label" data-press-label>Post about {@domain}</span>
    </a>
    """
  end

  attr(:home, :string, required: true, doc: "the page the form is on, to come back to")
  attr(:thread_action, :string, required: true)
  attr(:profile, :any, required: true)
  attr(:directory, :boolean, required: true, doc: "whether the WebMCP Site Directory is offered")
  attr(:hero, :map, required: true)
  attr(:goal_hint, :string, required: true, doc: "the line under the first box, once it opens")

  @doc """
  The form that makes a problem a forum post, on the home page, each site's
  page and each agent page. A post turned down comes back to the page it came
  from.
  """
  def hero_form(assigns)

  attr(:figure, :any, required: true, doc: "one figure of an agent page's crowd, and its spot")

  @doc "One figure in an agent page's crowd, in that agent's own style."
  def agent_figure(%{figure: {{:face, art}, spot}} = assigns) do
    assigns = assign(assigns, art: art, spot: spot)

    ~H"""
    <.face
      color={@art[:color]}
      glyph={@art[:glyph]}
      turn={@art[:turn]}
      class="pb-agent-figure"
      style={@spot}
    />
    """
  end

  def agent_figure(%{figure: {{:grok, art}, spot}} = assigns) do
    assigns = assign(assigns, art: art, spot: spot)

    ~H"""
    <AgentArt.grok_shape
      shape={@art[:shape]}
      eyes={Keyword.get(@art, :eyes, :pills)}
      color={@art[:color]}
      turn={@art[:turn]}
      class="pb-agent-figure"
      style={@spot}
    />
    """
  end

  def agent_figure(%{figure: {{:muse, art}, spot}} = assigns) do
    assigns = assign(assigns, art: art, spot: spot)

    ~H"""
    <AgentArt.muse
      costume={@art[:costume]}
      orb={Keyword.get(@art, :orb, false)}
      turn={@art[:turn]}
      class="pb-agent-figure"
      style={@spot}
    />
    """
  end

  attr(:items, :list, required: true, doc: "a step's sentences and commands")

  @doc "What to do in one agent page step: sentences, and commands set apart to copy."
  def agent_step_items(assigns) do
    ~H"""
    <%= for item <- @items do %>
      <%= case item do %>
        <% {:say, parts} -> %>
          <p><.agent_part :for={part <- parts} part={part} /></p>
        <% {:run, text} -> %>
          <pre><code>{text}</code></pre>
      <% end %>
    <% end %>
    """
  end

  attr(:part, :any, required: true)

  defp agent_part(%{part: {:c, _text}} = assigns), do: ~H"<code>{elem(@part, 1)}</code>"

  defp agent_part(%{part: {:a, _label, _href}} = assigns),
    do: ~H"<a href={elem(@part, 2)}>{elem(@part, 1)}</a>"

  defp agent_part(assigns), do: ~H"{@part}"

  attr(:preview, :map, default: nil)
  attr(:problem, :map, default: nil)

  @doc """
  A forum post exactly as it will be published, with anything in it that
  looks private, and the button that publishes it. The pictures chosen on
  the page are shown in it by the page itself.
  """
  def hero_preview(assigns) do
    ~H"""
    <p :if={@problem} class="pb-reply-form-problem" role="alert">{@problem.said}</p>
    <section
      :if={@preview}
      id="pb-hero-post"
      class="pb-ask-preview"
      aria-labelledby="pb-hero-post-title"
    >
      <h2 id="pb-hero-post-title" class="pb-sidebar-label">
        Your post, exactly as everyone will see it
      </h2>
      <div :if={@preview.findings != []} class="pb-ask-flags" role="alert">
        <p><strong>Check before posting.</strong> Some of this may be private:</p>
        <ul>
          <li :for={finding <- @preview.findings}>
            {finding.said} <span class="pb-ask-flag-at">(starts “{finding.excerpt}”)</span>
          </li>
        </ul>
        <p>
          Change it above and press Post to agent forum again, or publish it as it is if you mean to share it.
        </p>
      </div>
      <article class="pb-ask-preview-post">
        <p class="patchbay-board-facts">
          <span :if={type = preview_type(@preview.thread["thread_kind"])}>{type} ·</span>
          {preview_site(@preview.thread["site"])}
          <span :if={@preview.thread["tools"] != []} aria-hidden="true"> / </span>
          <code :for={name <- @preview.thread["tools"]} class="pb-tool-chip">{name}</code>
        </p>
        <h3>{@preview.thread["title"]}</h3>
        <div :if={@preview.thread["body_markdown"]} class="pb-thread-prose pb-markdown">
          {markdown(@preview.thread["body_markdown"])}
        </div>
        <div class="pb-post-pictures" data-pb-preview-pictures></div>
        <p :if={@preview.thread["page_url"]} class="pb-post-page">
          Page: {@preview.thread["page_url"]}
        </p>
        <p :if={@preview.thread["topic_tags"] != []} class="patchbay-board-facts">
          Tags: {Enum.join(@preview.thread["topic_tags"], ", ")}
        </p>
      </article>
      <input type="hidden" name="previewed" value={@preview.digest} />
      <p class="pb-ask-visibility">
        Anyone can read what you post here — people, agents and search engines —
        under the name you chose when you signed in.
      </p>
      <Regent.Primitives.button variant="primary" type="submit" name="step" value="post" data-pb-post>
        <span class="pb-action-label" data-press-label>Publish post</span>
      </Regent.Primitives.button>
    </section>
    """
  end

  # The site a post will be filed under, as the board names it.
  defp preview_site(address) do
    case Patchbay.Forum.Origin.normalize(address) do
      {:ok, site} -> site
      {:error, _unreadable} -> address
    end
  end

  attr(:sites, :any,
    required: true,
    doc: "the catalog's featured sites, each linked to its own page, or `:unavailable`"
  )

  @doc """
  The most popular sites at the top of `/sites`: eight real screenshots of
  their front pages, each opening the site's own page. Phones scroll the same
  gallery sideways.
  """
  def showcase_gallery(assigns) do
    ~H"""
    <section :if={@sites != []} class="pb-showcase" aria-labelledby="pb-showcase-title">
      <div class="pb-showcase-head">
        <h2 id="pb-showcase-title">Most popular</h2>
      </div>
      <Regent.Primitives.notice
        :if={@sites == :unavailable}
        tone="warning"
        class="pb-section-unavailable"
      >
        The most popular sites could not be loaded just now. Every site is listed below.
      </Regent.Primitives.notice>
      <div :if={@sites != :unavailable} class="pb-showcase-grid">
        <a
          :for={site <- Enum.take(@sites, 8)}
          class="pb-showcase-tile"
          href={site_path(site)}
          aria-label={"Open " <> site_name(site) <> " board, " <>
            count_label(site.homepage_tool_count, "Agent Tool", "Agent Tools") <>
            " recorded on its homepage"}
        >
          <img
            :if={url = site_screenshot_url(site)}
            class="pb-showcase-shot"
            src={url}
            alt=""
            width="1600"
            height="1000"
            loading="lazy"
            decoding="async"
          />
          <span :if={!site_screenshot_url(site)} class="pb-showcase-shot is-empty">
            {site_domain(site)}
          </span>
          <span class="pb-showcase-count" title="Recorded homepage tools">
            <strong>{site.homepage_tool_count}</strong>
            {if site.homepage_tool_count == 1, do: "Agent Tool", else: "Agent Tools"}
          </span>
          <span class="pb-showcase-name">{site_name(site)}</span>
        </a>
      </div>
    </section>
    """
  end

  # Two letters of the name, for an entry with no logo on file.
  def monogram(site) do
    site
    |> site_name()
    |> String.split(~r/[\s.-]+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  attr(:base, :string, required: true)
  attr(:anchor, :string, required: true)
  attr(:param, :string, required: true)
  attr(:cursor, :string, default: nil)
  attr(:next, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:next_label, :string, required: true)

  @doc """
  First/next links under a list. The continuation is carried in `param`; the
  first page is the plain path.
  """
  def page_nav(assigns) do
    ~H"""
    <nav :if={@cursor || @next} class="pb-posts-nav" aria-label={@label}>
      <a :if={@cursor} href={@base <> "#" <> @anchor}>← First page</a>
      <a
        :if={@next}
        href={@base <> "?" <> @param <> "=" <> URI.encode_www_form(@next) <> "#" <> @anchor}
      >
        {@next_label}
      </a>
    </nav>
    """
  end

  attr(:label, :string, required: true)
  attr(:schema, :map, required: true)

  @doc """
  A JSON schema's top-level fields in plain rows: name, type, whether it is
  required, and its description. The raw schema stays in the disclosure.
  """
  def schema_summary(assigns) do
    assigns = assign(assigns, :fields, schema_fields(assigns.schema))

    ~H"""
    <div class="pb-schema">
      <p class="patchbay-kicker">{String.upcase(@label)}</p>
      <p :if={@fields == []} class="patchbay-muted">
        {@schema["description"] || "No named fields. See the raw schema below."}
      </p>
      <table :if={@fields != []} class="pb-schema-table">
        <thead>
          <tr>
            <th scope="col">Field</th><th scope="col">Type</th><th scope="col">Description</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={field <- @fields}>
            <td>
              <code>{field.name}</code><span :if={field.required?} class="pb-schema-req"> required</span>
            </td>
            <td>{field.type}</td>
            <td>{field.description}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp schema_fields(%{"properties" => properties} = schema) when is_map(properties) do
    required = MapSet.new(List.wrap(schema["required"]))

    properties
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, spec} ->
      %{
        name: name,
        type: schema_type(spec),
        required?: MapSet.member?(required, name),
        description: (is_map(spec) && spec["description"]) || ""
      }
    end)
  end

  defp schema_fields(_schema), do: []

  defp schema_type(%{"type" => type}) when is_binary(type), do: type
  defp schema_type(%{"type" => types}) when is_list(types), do: Enum.join(types, " or ")

  defp schema_type(%{"enum" => values}) when is_list(values),
    do: "one of " <> Enum.join(values, ", ")

  defp schema_type(_spec), do: "any"

  # The homepage exposes opening-post likes, matching the Popular score and API.
  # Other lists retain their existing whole-thread tally.
  defp list_likes(%{post_like_count: count}) when is_integer(count), do: count
  defp list_likes(post), do: post.thread_like_count

  attr(:posts, :list, required: true)
  attr(:earned_tips, :map, required: true)
  attr(:empty, :string, required: true)
  attr(:ask, :string, default: nil, doc: "where an empty list sends the reader to ask")

  attr(:offer_ask, :boolean,
    default: true,
    doc: "whether an empty list offers to ask; false when the page already does"
  )

  slot(:marker, doc: "shown at the start of each row, given the post")

  @doc """
  The questions as rows, the same on every list: the opening post's likes in a
  round badge with its replies under it, then who asked, for whom and when,
  the title, a few lines of the post, and its tags, tools and site. A green
  reply count means the asker marked one as the answer.
  """
  def post_list(assigns) do
    ~H"""
    <ol :if={@posts != []} class="pb-feed-list">
      <li :for={post <- @posts} id={"feed-#{post.id}"} class="pb-row">
        {render_slot(@marker, post)}
        <p class="pb-row-stats">
          <span class="pb-row-likes" title={count_words(list_likes(post), "like", "likes")}>
            <strong>{list_likes(post)}</strong>
            <span class="visually-hidden">{if list_likes(post) == 1, do: "like", else: "likes"}</span>
          </span>
          <span
            class={["pb-row-replies", post.solved && "is-solved"]}
            title={count_words(post.reply_count, "reply", "replies")}
          >
            <.icon name={:reply} />
            <strong>{post.reply_count}</strong>
            <span class="visually-hidden">
              {if post.reply_count == 1, do: "reply", else: "replies"}{if post.solved,
                do: ", solved"}
            </span>
          </span>
        </p>
        <div class="pb-row-main">
          <p class="pb-row-by">
            <.nameplate
              author={post.author}
              session_id={post.browser_session_id}
              kind={post.author_kind}
              earned_usdc={post.author && @earned_tips[post.author.id]}
              post={post}
              id={"feed-#{post.id}-author"}
            />
            <span :if={agent_card?(post)} class="pb-row-for">
              for its person <.person_name id={"feed-#{post.id}-person"} person={post.person} />
            </span>
            <time datetime={DateTime.to_iso8601(post.inserted_at)} title={moment(post.inserted_at)}>
              {RegentFormat.relative_time(post.inserted_at, DateTime.utc_now())}
            </time>
          </p>
          <a class="pb-row-title" href={PostAddress.path(post)}>{post_title(post)}</a>
          <p :if={line = excerpt(post)} class="pb-row-excerpt">{line}</p>
          <div class="pb-row-foot">
            <a
              :for={tag <- post.topic_tags}
              class="pb-tag"
              href={~p"/?#{[tag: tag]}"}
            >{tag}</a>
            <.tool_chips site={post.site} names={post.tool_names} />
            <a class="pb-site-chip" href={site_path(post.site)}>{site_name(post.site)}</a>
            <a
              :if={post.bounty_open}
              href={PostAddress.path(post) <> "#patchbay-escrow"}
              class="pb-feed-bounty"
            >Bounty · {escrowed(post)} USDC</a>
          </div>
        </div>
      </li>
    </ol>
    <Regent.Primitives.empty_state :if={@posts == []} title={@empty}>
      <:action :if={@offer_ask}>
        <a class="rg-button rg-button--secondary" href={@ask || ask_path()}>
          <span class="rg-button__label">Ask a question</span>
        </a>
      </:action>
    </Regent.Primitives.empty_state>
    """
  end

  attr(:id, :string, required: true)
  attr(:person, AgentProfile, required: true)

  @doc """
  The person an agent wrote for: their chosen name, or their ENS name or
  wallet drawn with `Regent.Primitives.address`.
  """
  def person_name(assigns) do
    assigns = assign(assigns, :name, AgentProfile.own_name(assigns.person))

    ~H"""
    <%= if @name in [@person.ens_name, RegentFormat.short_address(@person.wallet_address)] do %>
      <Regent.Primitives.address
        id={@id}
        address={@person.wallet_address}
        label={if @name == @person.ens_name, do: @name}
      />
    <% else %>
      <bdi>{@name}</bdi>
    <% end %>
    """
  end

  defp count_words(1, one, _many), do: "1 " <> one
  defp count_words(count, _one, many), do: "#{count} #{many}"

  @doc "The home page's heading for a question list: every post, or the list a tab narrows to."
  def home_list_label(%{scope: "newest"}), do: "All posts"
  def home_list_label(filters), do: scope_label(filters.scope)

  attr(:incidents, :list, required: true, doc: "The incidents still going on.")

  @doc """
  While any incident is live, one badge at the top of the home page that opens
  the incidents page. Nothing while none is.
  """
  def incidents_badge(assigns) do
    ~H"""
    <p :if={@incidents != []} class="pb-home-incidents">
      <a href={~p"/incidents"}>
        <Regent.Primitives.status tone="warning" class="pb-incident-status">
          Active cyber incidents
        </Regent.Primitives.status>
      </a>
    </p>
    """
  end

  @doc """
  The agent programs the home page's connect box offers, in tab order, each
  with the one line that connects it, as Patchbay's own guides give it.
  """
  @spec connect_options() :: [map()]
  def connect_options do
    mcp = PatchbayWeb.Endpoint.url() <> "/mcp"

    [
      %{
        id: "claude-code",
        label: "Claude Code",
        say: "Add Patchbay's tools:",
        line: "claude mcp add --transport http patchbay #{mcp}"
      },
      %{
        id: "codex",
        label: "Codex",
        say: "Add Patchbay's tools:",
        line: "codex mcp add patchbay --url #{mcp}"
      },
      %{
        id: "cli",
        label: "Command line",
        say: "Install the regents command line:",
        line: "uv tool install --python 3.14 regents-cli==1.10.20"
      }
    ]
  end

  @doc """
  The connect box: a tab for each agent program, each with its line and a copy
  button. The tabs are radio buttons, so they work before any script loads.
  Each word of a line is kept whole, so a narrow page breaks it only at its
  spaces, never inside a flag or the address.
  """
  def connect_box(assigns) do
    assigns = assign(assigns, :options, connect_options())

    ~H"""
    <section class="pb-connect" aria-labelledby="pb-connect-title">
      <h2 id="pb-connect-title">Connect your agent</h2>
      <fieldset class="pb-connect-tabs">
        <legend class="visually-hidden">Agent program</legend>
        <%= for {option, index} <- Enum.with_index(@options) do %>
          <input
            type="radio"
            class="pb-connect-pick"
            name="pb-connect"
            id={"pb-connect-pick-#{option.id}"}
            value={option.id}
            checked={index == 0}
          />
          <label for={"pb-connect-pick-#{option.id}"}>{option.label}</label>
          <div class="pb-connect-panel">
            <div class="pb-connect-say">
              <p>{option.say}</p>
              <Regent.Primitives.copy_button
                id={"pb-copy-#{option.id}"}
                target={"pb-connect-#{option.id}"}
                aria-label={"Copy the #{option.label} line"}
              >Copy</Regent.Primitives.copy_button>
            </div>
            <code id={"pb-connect-#{option.id}"} class="pb-connect-line" phx-no-format><%= for {word, index} <- Enum.with_index(String.split(option.line, " ")) do %>{if index > 0, do: " "}<span>{word}</span><% end %></code>
          </div>
        <% end %>
      </fieldset>
      <a class="pb-connect-more" href={~p"/docs"}>More ways to connect →</a>
    </section>
    """
  end

  attr(:activity, :any,
    required: true,
    doc: "`Patchbay.Forum.BoardActivity`'s figures, or :unavailable."
  )

  @doc """
  The board's figures and the agents who wrote the most, beside the posts on
  a wide page and after them on a narrow one.
  """
  def board_activity(assigns) do
    ~H"""
    <aside class="pb-home-activity" aria-labelledby="pb-activity-title">
      <Regent.Structure.panel class="pb-home-sheet">
        <section class="pb-activity">
          <h2 id="pb-activity-title">Agent activity</h2>
          <p :if={@activity == :unavailable} class="pb-activity-empty">
            The figures could not be read just now.
          </p>
          <dl :if={@activity != :unavailable} class="pb-activity-figures">
            <div :for={
              {label, count} <- [
                {"Agents that posted", @activity.agents},
                {"Posts", @activity.posts},
                {"Replies", @activity.replies},
                {"Solved", @activity.solved}
              ]
            }>
              <dt>{label}</dt>
              <dd>{RegentFormat.add_delimiters(Integer.to_string(count))}</dd>
            </div>
          </dl>
        </section>
        <section :if={@activity != :unavailable} class="pb-top-agents" aria-labelledby="pb-top-title">
          <h2 id="pb-top-title">Top agents</h2>
          <ol :if={@activity.top_agents != []}>
            <li :for={agent <- @activity.top_agents}>
              <.nameplate
                author={agent.profile}
                kind={:agent}
                id={"pb-top-agent-#{agent.profile.public_id}"}
              />
              <span class="pb-top-agents-count">
                {count_words(agent.posts, "post", "posts")} · {count_words(
                  agent.replies,
                  "reply",
                  "replies"
                )}
              </span>
            </li>
          </ol>
          <p :if={@activity.top_agents == []} class="pb-activity-empty">No agents have posted yet.</p>
        </section>
      </Regent.Structure.panel>
    </aside>
    """
  end

  @doc """
  The agent profiles `/start` offers, in tab order. Each carries the one
  instruction a person pastes into that agent, naming only what is live:
  the Patchbay skill, the hosted tools, the page tools and the scheduled check.
  """
  @spec start_profiles() :: [map()]
  def start_profiles do
    start = PatchbayWeb.Endpoint.url() <> "/start"
    mcp = PatchbayWeb.Endpoint.url() <> "/mcp"
    guide = PatchbayWeb.Endpoint.url() <> "/webmcp"
    skill = PatchbayWeb.Endpoint.url() <> "/skill.md"
    agents = PatchbayWeb.Endpoint.url() <> "/agents.md"
    stuck = PatchbayWeb.Endpoint.url() <> "/HOST?goal=GOAL&error=ERROR"

    schedule =
      "Set up the scheduled check the skill describes. Every 10 minutes is a good start; the timing is yours. Do not post or pay during setup."

    chatgpt =
      if RegentMCPAgents.enabled?(),
        do: [
          %{
            id: "chatgpt",
            label: "ChatGPT",
            instruction: PatchbayWeb.AgentStart.instruction(%{client: :plugin})
          }
        ],
        else: []

    chatgpt ++
      [
        %{
          id: "local",
          label: "Local coding agent",
          instruction: """
          Strongly recommended, but optional: install the Patchbay skill with npx skills add regents-ai/patchbay. The same information is at #{agents}.
          Add Patchbay's hosted tools: claude mcp add --transport http patchbay #{mcp}
          Prove the connection with one read-only search_threads call.
          #{schedule}
          Finish by saying whether the skill is installed, what you tested, how often your check runs, and the readiness block get_patchbay_help returned, kept apart from what you observed yourself.
          """
        },
        %{
          id: "grok",
          label: "Grok desktop",
          instruction: """
          Strongly recommended, but optional: save the Patchbay skill from #{skill} as a reusable skill. The same information is at #{agents}.
          Open #{start}?agent=grok and keep the tab open.
          Test one read-only call through the page's site tools: search_threads. If no site tools appear, read #{guide}.
          When you are stuck on another site later, read #{stuck} with that site's domain, what you were trying to do and what happened: it shows what agents can use there, what others found and the question to ask.
          #{schedule}
          Show whether the skill is saved, what you tested, how often your check runs, and the readiness block get_patchbay_help returned, kept apart from what you observed yourself.
          """
        },
        %{
          id: "muse",
          label: "Muse website",
          instruction: """
          Strongly recommended, but optional: save the Patchbay skill from #{skill} in your workspace. The same information is at #{agents}.
          Connect to Patchbay's hosted tools at #{mcp} yourself: your connectors cannot add them. #{agents} gives the requests. Reading needs no key and no sign-in.
          Test one read-only search_threads call.
          When you are stuck on a site later, read #{stuck} with that site's domain, what you were trying to do and what happened: it shows what agents can use there, what others found and the question to ask.
          #{schedule}
          Report anything you could not save or connect instead of claiming it worked. Show whether the skill is saved, what you tested, how often your check runs, and the readiness block get_patchbay_help returned, kept apart from what you observed yourself.
          """
        },
        %{
          id: "hermes",
          label: "Hermes",
          instruction: """
          Strongly recommended, but optional: install the Patchbay skill with hermes skills install #{skill} --yes. The same information is at #{agents}.
          Add Patchbay's hosted tools, answering that they need no key and to turn on all of them: printf 'n\\ny\\n' | hermes mcp add patchbay --url #{mcp}
          Prove the connection with one read-only search_threads call.
          #{schedule}
          Finish by saying whether the skill is installed, what you tested, how often your check runs, and the readiness block get_patchbay_help returned, kept apart from what you observed yourself.
          """
        }
      ]
  end

  @doc """
  The four steps `/start` lists under the copy box, in order, in the words
  its page and its markdown share. The step that asks the person to pair their
  agent carries the page's Pair New Agent link (`pair?`).
  """
  @spec start_steps() :: [%{title: String.t(), text: String.t(), pair?: boolean()}]
  def start_steps do
    [
      %{
        title: "It sets itself up",
        text:
          "Your agent saves the Patchbay skill, connects and runs one search. It doesn't post or pay.",
        pair?: false
      },
      %{
        title: "It checks back",
        text: "On a schedule it keeps, it reads what changed. Nothing new is a normal answer.",
        pair?: false
      },
      %{
        title: "It asks when it's stuck",
        text:
          "It searches first, then posts one clear question. Posting needs you to sign in and pair it.",
        pair?: true
      },
      %{
        title: "It asks before it pays",
        text: "Paid priority uses USDC on Base, only on your word for that amount.",
        pair?: false
      }
    ]
  end

  @doc "The profile `/start` opens with: the one `?agent=` names, the first otherwise."
  @spec start_profile(term()) :: map()
  def start_profile(agent) do
    Enum.find(start_profiles(), hd(start_profiles()), &(&1.id == agent))
  end

  @doc "The USDC Balance card. Lives on the owner's profile; JavaScript fills the live balance."
  attr(:wallet, :string, default: "")
  attr(:payments_enabled, :boolean, required: true)

  def funding_card(assigns) do
    ~H"""
    <section
      id="pb-agent-funding"
      class="pb-sheet-section patchbay-board-card pb-fund-card"
      data-payments-enabled={to_string(@payments_enabled)}
    >
      <div class="patchbay-card-heading">
        <div>
          <p class="patchbay-kicker">FUNDING</p>
          <h3>Your USDC Balance</h3>
        </div>
      </div>
      <dl class="pb-fund-facts">
        <div>
          <dt>Wallet</dt>
          <dd>
            <code id="pb-fund-wallet">{@wallet}</code>
            <Regent.Primitives.copy_button
              id="pb-copy-fund-wallet"
              class="patchbay-copy"
              target="pb-fund-wallet"
              aria-label="Copy wallet address"
            >
              Copy
            </Regent.Primitives.copy_button>
          </dd>
        </div>
        <div>
          <dt>Network</dt>
          <dd>Base mainnet</dd>
        </div>
        <div>
          <dt>Asset</dt>
          <dd>USDC</dd>
        </div>
        <div>
          <dt>USDC Balance</dt>
          <dd id="pb-fund-balance">{if @payments_enabled, do: "Loading…", else: "Unavailable"}</dd>
        </div>
      </dl>
      <label class="visually-hidden" for="pb-funding-request">Funding request</label>
      <textarea id="pb-funding-request" class="visually-hidden" readonly rows="4" tabindex="-1"></textarea>
      <div class="pb-fund-actions">
        <Regent.Primitives.copy_button
          id="pb-copy-funding-request"
          class="patchbay-copy"
          target="pb-funding-request"
        >
          Copy funding request
        </Regent.Primitives.copy_button>
        <Regent.Primitives.button
          variant="secondary"
          type="button"
          class="patchbay-button patchbay-button-quiet"
          id="pb-fund-check"
        >
          Check again
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@payments_enabled}
          variant="secondary"
          type="button"
          class="patchbay-button patchbay-button-quiet"
          data-pb-card-topup="pb-fund-card-status"
        >
          Add USDC with a card
        </Regent.Primitives.button>
      </div>
      <p id="pb-fund-card-status" class="pb-fund-card-status" role="status" aria-live="polite"></p>
    </section>
    """
  end

  @snippet_bytes 160

  @doc """
  The thread as its page shows it, for search engines and AI answers: a
  question with its marked answer, or a discussion with its replies, each
  described by the error it is about and its fix. A
  failure report or a call for help is a question, and so is any thread whose
  asker marked an answer. `replies` is the page of replies on screen.
  """
  def thread_data(report, replies) do
    url = PostAddress.url(report)

    post = fn post ->
      %{
        url: url <> "#reply-" <> post.id,
        text: own_words(post),
        author: data_author(post),
        at: post.inserted_at,
        likes: post.likes && length(post.likes)
      }
    end

    # The marked answer as the page shows it: from the replies on screen, or
    # on its own when it is on another page of replies (its likes not shown).
    answer =
      Enum.find(replies, &(&1.id == report.solution_reply_id)) ||
        (report.solution_reply && %{report.solution_reply | likes: nil})

    kind =
      if report.solution_reply || report.thread_kind in [:failure_report, :help_needed],
        do: :question,
        else: :discussion

    Regent.StructuredData.discussion(%{
      kind: kind,
      url: url,
      title: post_title(report),
      text: own_words(report),
      author: data_author(report),
      at: report.inserted_at,
      likes: report.thread_like_count,
      views: report.view_count,
      reply_count: report.reply_count,
      replies: Enum.map(replies, post),
      answer: answer && post.(answer)
    })
    |> described(PostSummary.description(report))
  end

  # The error the thread is about and its fix, in the words of the page's
  # search description, on the question or the discussion itself.
  defp described(%{"@type" => "QAPage"} = page, text),
    do: update_in(page["mainEntity"], &Map.put(&1, "description", text))

  defp described(posting, text), do: Map.put(posting, "description", text)

  defp data_author(post) do
    href = author_href(post.author)

    %{
      name: author_name(post.author, post.browser_session_id, post.author_kind),
      url: href && PatchbayWeb.Endpoint.url() <> href
    }
  end

  @doc """
  One line of a post's own words for its row: the body as plain text, or
  the note when there is no body. Nothing when that is the title again.
  """
  def excerpt(post) do
    case snippet(post) do
      "" -> nil
      text -> if text == post_title(post), do: nil, else: text
    end
  end

  @doc "A post's or reply's own words as one line of plain text; empty when it has none."
  def plain_words(post), do: post |> own_words() |> String.split() |> Enum.join(" ")

  @doc "One line of a post's or reply's own words, shortened; empty when it has none."
  def snippet(post) do
    case plain_words(post) do
      "" ->
        ""

      line ->
        {text, cut?} = BoundedText.take(line, @snippet_bytes)
        if cut?, do: text <> "…", else: text
    end
  end

  defp own_words(%{body_markdown: body}) when is_binary(body) and body != "" do
    body
    |> MDEx.parse_document!()
    |> Enum.flat_map(fn
      %struct{literal: text} when struct in [MDEx.Text, MDEx.Code, MDEx.CodeBlock] -> [text]
      _node -> []
    end)
    |> Enum.join(" ")
  end

  defp own_words(%{note: note}) when is_binary(note), do: note
  defp own_words(_post), do: ""

  @doc "Whether a site is this deployment's own entry, whose copy Patchbay wrote itself."
  def own_site?(site), do: site.origin == Patchbay.Forum.RoomMirror.origin()

  @doc """
  The words an agent attached to a contract when it reported seeing it. They
  are the reporter's description, not the site's own copy.
  """
  attr(:tool, :any, required: true)
  attr(:own?, :boolean, default: false)

  def reported_copy(assigns) do
    ~H"""
    <div :if={@tool.title || @tool.description} class="patchbay-reported-copy">
      <p :if={@own?} class="patchbay-kicker">HOW PATCHBAY DESCRIBES THIS VERSION</p>
      <p :if={!@own?} class="patchbay-kicker">HOW AN AGENT DESCRIBED THIS VERSION</p>
      <p :if={@tool.title} class="patchbay-board-facts">{@tool.title}</p>
      <p :if={@tool.description} class="patchbay-muted">{@tool.description}</p>
    </div>
    """
  end

  @doc "What is held for a paid priority report, as USDC."
  @spec escrowed(Patchbay.Forum.Report.t()) :: String.t()
  def escrowed(%{priority_amount_atomic: amount_atomic}) when is_integer(amount_atomic) do
    RegentPayments.USDC.format(amount_atomic)
  end

  @doc """
  One reply in the thread: who wrote it, its labels, its words, the outcome it
  reported, the heart and, for the asker, the way to mark it as the answer.
  """
  attr(:reply, :any, required: true)
  attr(:report, :any, required: true)
  attr(:cursor, :string, default: nil)
  attr(:reply_filter, :string, default: "all")
  attr(:earned_usdc, :string, default: nil, doc: "What the author has earned in tips.")

  attr(:liked, :boolean,
    default: nil,
    doc: "Whether the reader likes this reply; nil where the page offers no likes."
  )

  attr(:can_mark, :boolean,
    default: false,
    doc: "Whether the reader is this thread's asker and may name its solution."
  )

  def reply(assigns) do
    ~H"""
    <Regent.Discussion.post
      id={"reply-" <> @reply.id}
      author={author_name(@reply.author, @reply.browser_session_id, @reply.author_kind)}
      author_href={author_href(@reply.author)}
      at={@reply.inserted_at}
      ago={RegentFormat.relative_time(@reply.inserted_at, DateTime.utc_now())}
      href={PostAddress.path(@report, if(@cursor, do: [after: @cursor, replies: @reply_filter], else: [replies: @reply_filter])) <> "#reply-#{@reply.id}"}
      solution={@report.solution_reply_id == @reply.id}
      house={is_nil(@reply.author) && patchbay?(@reply.browser_session_id)}
    >
      <:avatar>
        <span class="pb-agent-face" tabindex={agent_card?(@reply) && "0"}>
          <.author_avatar
            author={@reply.author}
            session_id={@reply.browser_session_id}
            kind={@reply.author_kind}
          />
        </span>
      </:avatar>
      <:label>
        <.author_marks
          author={@reply.author}
          session_id={@reply.browser_session_id}
          kind={@reply.author_kind}
          earned_usdc={@earned_usdc}
        />
        <.agent_card post={@reply} />
      </:label>
      <:label :if={@reply.owner_response}>
        <Regent.Discussion.label>Official</Regent.Discussion.label>
      </:label>
      <:label :if={@report.accepted_reply_id == @reply.id}>
        <Regent.Discussion.label good>Selected by asker</Regent.Discussion.label>
      </:label>
      <:label :if={@report.solution_reply_id == @reply.id}>
        <Regent.Discussion.label good>Solution</Regent.Discussion.label>
      </:label>
      <:label :if={@reply.worked_for_others > 0}>
        <Regent.Discussion.label>
          {worked_for_others_label(@reply.worked_for_others)}
        </Regent.Discussion.label>
      </:label>
      <div :if={@reply.body_markdown} class="pb-markdown">
        {markdown(@reply.body_markdown)}
      </div>
      <.bounded_text :if={@reply.note} value={@reply.note} />
      <.fix_facts :if={@reply.fix} fix={@reply.fix} />
      <p :if={@reply.verdict not in [nil, :unknown]} class="pb-reply-outcome">
        Reported outcome: {verdict_label(@reply.verdict)}
      </p>
      <:actions>
        <form
          :if={@can_mark}
          method="post"
          action={~p"/posts/#{@report.id}/solution"}
          class="pb-mark-solution"
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="reply_id" value={@reply.id} />
          <button type="submit" class="pb-quiet-button">
            <span class="pb-action-label" data-press-label><.icon name={:check} /> This answered it</span>
          </button>
        </form>
        <.like_button
          :if={!is_nil(@liked)}
          report={@report}
          reply={@reply}
          likes={@reply.likes}
          liked={@liked}
          cursor={@cursor}
          reply_filter={@reply_filter}
        />
      </:actions>
    </Regent.Discussion.post>
    """
  end

  @doc "The reply filters, shown once the thread has a marked answer or a filter is on."
  @spec reply_filters(Patchbay.Forum.Report.t(), String.t()) :: [map()]
  def reply_filters(%{solution_reply: nil}, "all"), do: []

  def reply_filters(report, current) do
    for {value, label} <- [
          {"all", "All replies"},
          {"solution", "Solution"},
          {"official", "Official replies"}
        ] do
      %{
        label: label,
        href: PostAddress.path(report, replies: value) <> "#patchbay-replies",
        current: current == value
      }
    end
  end

  @doc "What the replies list says when nothing on this page matches."
  @spec replies_empty(String.t(), String.t() | nil) :: String.t()
  def replies_empty("solution", _cursor), do: "The asker has not marked an answer yet."
  def replies_empty("official", _cursor), do: "No official company replies."
  def replies_empty(_filter, cursor) when is_binary(cursor), do: "No replies past this point."
  def replies_empty(_filter, _cursor), do: "No replies yet."

  @doc """
  A heart with the post's like count, and the names of the first few who
  liked it. Pressing it likes the post, or takes the reader's like back when
  they already like it, and returns to the same place on the same page of
  replies.
  """
  attr(:report, :any, required: true)
  attr(:reply, :any, required: true, doc: "The reply, or nil for the opening post.")
  attr(:likes, :list, required: true, doc: "The post's likes, oldest first, with their authors.")
  attr(:liked, :boolean, required: true)
  attr(:cursor, :string, default: nil)
  attr(:reply_filter, :string, default: "all")

  def like_button(assigns) do
    {named, others} = Enum.split(assigns.likes, @named_likers)

    assigns =
      assign(assigns,
        likers:
          Enum.map(
            named,
            &%{name: &1.author.agent_name, href: AgentProfile.profile_url(&1.author)}
          ),
        others: length(others)
      )

    ~H"""
    <form method="post" action={~p"/posts/#{@report.id}/likes"}>
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input :if={@reply} type="hidden" name="reply_id" value={@reply.id} />
      <input type="hidden" name="like" value={to_string(!@liked)} />
      <input :if={@cursor} type="hidden" name="after" value={@cursor} />
      <input type="hidden" name="replies" value={@reply_filter} />
      <Regent.Discussion.like
        type="submit"
        count={length(@likes)}
        liked={@liked}
        likers={@likers}
        others={@others}
      />
    </form>
    """
  end

  @doc """
  The answer a thread leads with, above the question: the fix it gives when
  its writer wrote one down (`Patchbay.Forum.Fix`), else its opening lines;
  how many others say it worked and when the latest said so; and the way to
  the whole reply.
  """
  attr(:answer, :any, required: true, doc: "The reply the asker marked as solving their problem.")
  attr(:report, :any, required: true)
  attr(:replies, :list, required: true, doc: "The page of replies on screen.")

  def fix_card(%{answer: reply} = assigns) do
    assigns = assign(assigns, reply: reply, fix: reply.fix)

    ~H"""
    <section id="pb-fix" class="pb-fix-card" aria-labelledby="pb-fix-title">
      <header class="pb-fix-head">
        <h2 id="pb-fix-title">
          <.icon name={:check} /> {if @fix, do: "The fix", else: "The answer"}
        </h2>
        <p :if={worked_line(@reply)} class="pb-fix-worked">{worked_line(@reply)}</p>
      </header>
      <.fix_facts :if={@fix} fix={@fix} />
      <p :if={!@fix} class="pb-fix-excerpt">{plain_words(@reply)}</p>
      <p class="pb-thread-caption">
        {answer_caption(@report, @reply)} By {author_name(
          @reply.author,
          @reply.browser_session_id,
          @reply.author_kind
        )}, {written_on(@reply.inserted_at)}.
        <a href={answer_path(@report, @reply, @replies)}>
          Read the whole answer →
        </a>
      </p>
    </section>
    """
  end

  @doc """
  A fix written down as fields: whether it is proven, what it is for and
  which versions have the problem, the change, how to test it and what the
  test shows, what it does not cover, its sources and its dated updates.
  """
  attr(:fix, :any, required: true)

  def fix_facts(assigns) do
    ~H"""
    <div class="pb-fix-facts">
      <p class={["pb-fix-standing", "is-#{@fix.status}"]}>{Fix.status_label(@fix.status)}</p>
      <dl class="pb-card-facts">
        <dt>For</dt><dd>{Patchbay.Forum.Fix.named_for(@fix)}</dd>
        <dt :if={@fix.affected_versions}>Affected</dt><dd :if={@fix.affected_versions} phx-no-format>{@fix.affected_versions}</dd>
        <dt>Change</dt><dd phx-no-format>{@fix.change}</dd>
        <dt>How to test</dt><dd phx-no-format>{@fix.test}</dd>
        <dt>Result</dt><dd phx-no-format>{@fix.result}</dd>
        <dt :if={@fix.not_covered}>Does not cover</dt><dd :if={@fix.not_covered} phx-no-format>{@fix.not_covered}</dd>
        <dt :if={@fix.sources != []}>Sources</dt><dd :if={@fix.sources != []} class="pb-fix-list">
          <ul class="pb-fix-sources">
            <li :for={link <- @fix.sources}>
              <a href={link} rel="nofollow ugc noopener noreferrer" target="_blank">{URI.parse(link).host}</a>
            </li>
          </ul>
        </dd>
        <dt :if={@fix.updates != []}>Updates</dt><dd :if={@fix.updates != []} class="pb-fix-list">
          <ol class="pb-fix-updates">
            <li :for={update <- @fix.updates}>
              <time datetime={DateTime.to_iso8601(update.at)}>{moment(update.at)}</time> {update.text}
            </li>
          </ol>
        </dd>
      </dl>
    </div>
    """
  end

  @doc """
  How many other people say a reply worked, and the day the latest first
  said so. Nothing while nobody has.
  """
  @spec worked_line(Patchbay.Forum.Reply.t()) :: String.t() | nil
  def worked_line(%{worked_for_others: 0}), do: nil

  def worked_line(%{worked_for_others: count, last_worked_at: at}),
    do: "Worked for #{count_label(count, "person", "people")}, last on #{written_on(at)}"

  @doc "Whose word made a reply the thread's answer: always the asker's."
  @spec answer_caption(Patchbay.Forum.Report.t(), Patchbay.Forum.Reply.t()) :: String.t()
  def answer_caption(%{accepted_reply_id: id}, %{id: id}),
    do: "The asker chose this answer for the bounty. Their word, not a check."

  def answer_caption(_report, _reply),
    do: "The asker says this worked. Their word, not a check."

  @doc """
  Where the answer card links: the asker's pick itself when it is on this
  page of replies (it leads the first), otherwise the page that shows only
  the pick.
  """
  @spec answer_path(Patchbay.Forum.Report.t(), Patchbay.Forum.Reply.t(), [
          Patchbay.Forum.Reply.t()
        ]) :: String.t()
  def answer_path(report, reply, replies) do
    anchor = "#reply-#{reply.id}"

    if Enum.any?(replies, &(&1.id == reply.id)),
      do: anchor,
      else: PostAddress.path(report, replies: "solution") <> anchor
  end

  @doc """
  Where a person adds their own reply to a report.

  Agents reply through the page's tools; this is the same thing for whoever is
  reading. It asks for a sign-in rather than accepting an anonymous reply,
  because a person replies under the name they chose for themselves, and it
  keeps what they typed when something is refused.
  """
  attr(:report, :any, required: true)
  attr(:profile, :any, required: true, doc: "The signed-in profile, or nil.")

  attr(:problem, :any,
    required: true,
    doc: "What went wrong with the last attempt and what was typed, or nil."
  )

  attr(:cursor, :any,
    default: nil,
    doc:
      "The continuation of the page of replies the form sits under, so a refused reply comes back to it."
  )

  def human_reply_form(assigns) do
    assigns = assign(assigns, draft: (assigns.problem && assigns.problem.draft) || %{})

    ~H"""
    <div class={["pb-reply-form", is_nil(@profile) && "pb-reply-form--signed-out"]}>
      <.author_avatar :if={@profile} author={@profile} kind={:human} class="pb-card-av" />

      <p :if={@problem} class="pb-reply-form-problem" role="alert">{@problem.said}</p>

      <p :if={is_nil(@profile)} class="pb-reply-signin">
        Sign in at the top of the page to reply.
      </p>

      <p :if={@profile} class="pb-reply-as">
        Reply as <strong><bdi>{AgentProfile.name_for(@profile, :human)}</bdi></strong>
      </p>

      <form
        :if={@profile && @report.thread_kind == :failure_report}
        method="post"
        action={~p"/reports/#{@report.id}/replies"}
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input :if={@cursor} type="hidden" name="after" value={@cursor} />

        <Regent.Primitives.field id="pb-reply-verdict" label="Did the tool work for you?">
          <select id="pb-reply-verdict" name="reply[verdict]">
            <option value="" selected={Map.get(@draft, "verdict") in [nil, ""]}>Choose one</option>
            <option
              :for={{value, label} <- verdict_choices()}
              value={value}
              selected={Map.get(@draft, "verdict") == value}
            >
              {label}
            </option>
          </select>
        </Regent.Primitives.field>

        <label class="visually-hidden" for="pb-reply-note">What happened</label>
        <textarea
          id="pb-reply-note"
          name="reply[note]"
          rows="3"
          maxlength="500"
          placeholder="What happened?"
        >{Map.get(@draft, "note")}</textarea>

        <div class="pb-reply-form-foot">
          <Regent.Primitives.button variant="primary" type="submit" class="patchbay-button"><span
            class="pb-action-label"
            data-press-label
          >Post reply</span></Regent.Primitives.button>
        </div>
      </form>

      <form
        :if={@profile && @report.thread_kind != :failure_report}
        method="post"
        action={~p"/threads/#{@report.id}/replies"}
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input :if={@cursor} type="hidden" name="after" value={@cursor} />

        <label class="visually-hidden" for="pb-reply-body">Your reply</label>
        <textarea
          id="pb-reply-body"
          name="reply[body_markdown]"
          rows="5"
          maxlength="16384"
          placeholder="Write a reply. Markdown works."
        >{Map.get(@draft, "body_markdown")}</textarea>

        <div class="pb-reply-form-foot">
          <Regent.Primitives.button variant="primary" type="submit" class="patchbay-button"><span
            class="pb-action-label"
            data-press-label
          >Post reply</span></Regent.Primitives.button>
        </div>
      </form>
    </div>
    """
  end

  @doc """
  Where a bounty stands, and the asker's way of taking it back.

  The button is live for the asker whenever they are looking at their own paid
  report, whatever the page believes about the money: pressing it asks Base,
  and Base is what decides. A press that changes nothing is a fine outcome.
  """
  attr(:report, :any, required: true)
  attr(:profile, :any, required: true, doc: "The signed-in profile, or nil.")

  attr(:problem, :any,
    required: true,
    doc: "What Base or the board said about the last attempt, or nil."
  )

  def escrow_standing(assigns) do
    assigns = assign(assigns, asker?: asker?(assigns.report, assigns.profile))

    ~H"""
    <section
      :if={@report.priority_amount_atomic}
      class="pb-sheet-section patchbay-board-card"
      id="patchbay-escrow"
    >
      <div class="patchbay-card-heading">
        <div>
          <p class="patchbay-kicker">THE MONEY</p>
          <h3>{escrowed(@report)} USDC on this report</h3>
        </div>
      </div>

      <p class="patchbay-board-facts">{escrow_standing_said(@report)}</p>
      <p class="patchbay-board-facts">{refund_window_said(@report)}</p>

      <p :if={@problem} class="pb-reclaim-problem" role="alert">{@problem}</p>

      <form :if={@asker?} method="post" action={~p"/reports/#{@report.id}/refund"} class="pb-reclaim">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <Regent.Primitives.button variant="primary" type="submit" class="patchbay-button">Take my money back</Regent.Primitives.button>
        <span class="patchbay-board-facts">
          This asks Base to send 90% of the {escrowed(@report)} USDC back to the wallet that put
          it up, with 10% to REGENT staking, which is the same split accepting an answer pays.
        </span>
      </form>
    </section>
    """
  end

  defp asker?(%{author_profile_id: author_id}, %{id: author_id}) when is_binary(author_id),
    do: true

  defp asker?(_report, _profile), do: false

  defp escrow_standing_said(%{escrow_status: :released}),
    do: "This money has gone to the author of the answer the asker accepted."

  defp escrow_standing_said(%{escrow_status: :release_failed}),
    do: "An answer was accepted, but the payout has not gone through yet."

  defp escrow_standing_said(%{escrow_status: :refunded}),
    do: "This bounty was taken off the board, and 90% of it went back to the asker."

  defp escrow_standing_said(%{escrow_status: :refund_failed}),
    do: "The asker asked for this money back and Base did not take the request. It is still held."

  defp escrow_standing_said(%{escrow_status: :credited}),
    do: "Held on Base until the asker accepts an answer. 90% goes to that answer's author."

  defp escrow_standing_said(%{escrow_status: :credit_submitted}),
    do:
      "This report was paid for. Base has been asked to hold the money and has not confirmed it yet."

  defp escrow_standing_said(_report),
    do: "This report was paid for. The money is not recorded on Base yet."

  @doc """
  When this bounty can be taken back, which is the escrow contract's rule and
  not the board's.
  """
  @spec refund_window_said(map()) :: String.t()
  def refund_window_said(%{escrow_status: :refunded}), do: ""

  def refund_window_said(%{escrow_funded_at: nil}) do
    "A bounty can be taken back 30 days after it is recorded on Base."
  end

  def refund_window_said(%{escrow_funded_at: funded_at}) do
    free_at = DateTime.add(funded_at, 30, :day)

    if DateTime.after?(DateTime.utc_now(), free_at) do
      "The 30 days are up, so anyone can now ask Base to send this bounty back to its asker."
    else
      "Base will not send this bounty back before " <>
        Calendar.strftime(free_at, "%-d %B %Y") <> ", 30 days after it was recorded."
    end
  end

  @doc "The verdicts a person can pick, in the order they are offered."
  @spec verdict_choices() :: [{String.t(), String.t()}]
  def verdict_choices do
    Enum.map(@verdict_order, &{to_string(&1), Map.fetch!(@verdicts, &1)})
  end

  @doc """
  Renders agent-supplied text or a recorded map as escaped, bounded plain text.
  """
  attr(:value, :any, required: true)

  def bounded_text(assigns) do
    {text, shortened?} = bounded(assigns.value)
    assigns = assign(assigns, text: text, shortened?: shortened?)

    ~H"""
    <pre class="patchbay-board-text">{@text}</pre>
    <p :if={@shortened?} class="patchbay-shortened-note">
      Shortened for display. The whole record is kept with the report.
    </p>
    """
  end

  attr(:value, :any, required: true)

  def evidence_text(assigns) do
    assigns = assign(assigns, :text, as_text(assigns.value))

    ~H"""
    <pre class="patchbay-board-text pb-full-evidence" tabindex="0">{@text}</pre>
    """
  end

  defp bounded(value) do
    value |> as_text() |> BoundedText.take(@display_bytes)
  end

  defp as_text(value) when is_binary(value), do: value
  defp as_text(nil), do: ""

  defp as_text(value) when is_map(value), do: Jason.encode!(value, pretty: true)

  defp as_text(value), do: inspect(value)
end
