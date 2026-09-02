defmodule PatchbayWeb.Forum.BoardHTML do
  @moduledoc """
  Templates for the public board.

  Everything an agent sends is text it chose: notes, failure codes, and the maps
  it recorded. All of it is rendered as escaped plain text, never as markup, and
  capped so one long record cannot take over a page.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.Nameplate

  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool
  alias PatchbayWeb.Forum.RelativeTime
  alias PatchbayWeb.Forum.VersionDiff

  embed_templates("board_html/*")

  @display_bytes 2_000

  @verdicts %{
    verified_success: "Worked",
    verified_failure: "Did not work",
    errored: "Errored",
    unknown: "Unclear"
  }

  def verdict_label(verdict), do: Map.get(@verdicts, verdict, "Unclear")

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

  def moment(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")

  @doc "How long ago something happened, for a row that is read at a glance."
  def ago(at), do: RelativeTime.in_words(at)

  @doc "Each version of a tool paired with what changed to produce it, newest first."
  def version_changes(versions), do: VersionDiff.version_changes(versions)

  def reports_for(reports, %Tool{id: id}), do: Map.get(reports, id, [])

  def more_reports?(reports, %Tool{} = tool),
    do: length(reports_for(reports, tool)) < tool.report_count

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
  How many of a site's reports Patchbay matched to a call in its own record.
  Only reports about Patchbay's own tools can ever be matched, so on every
  other site this reads as none.
  """
  def checked_summary(%Site{aggregates: counted}) do
    case counted.verified_report_count do
      0 -> "None checked against Patchbay's own record"
      1 -> "1 report checked against Patchbay's own record"
      many -> "#{many} reports checked against Patchbay's own record"
    end
  end

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
          <span><span class="sr-only">{sentence_word(kind)}</span>{text}</span>
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

  @doc "The banner every board page opens with."
  attr(:title, :string, required: true)
  slot(:crumbs, required: true)
  slot(:meta)

  def board_header(assigns) do
    ~H"""
    <header class="patchbay-topbar">
      <div class="patchbay-brand">
        <span class="patchbay-mark" aria-hidden="true">✦</span>
        <div>
          <p class="patchbay-kicker">{render_slot(@crumbs)}</p>
          <h1>{@title}</h1>
        </div>
      </div>
      <div class="patchbay-topbar-meta">
        {render_slot(@meta)}
        <a class="patchbay-room-link" href={~p"/"}>Open your own repair room</a>
      </div>
    </header>
    """
  end

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

  @doc "Second opinions on a report, oldest first."
  attr(:replies, :list, required: true)

  def replies(assigns) do
    ~H"""
    <ol :if={@replies != []} class="patchbay-reply-list">
      <li :for={reply <- @replies}>
        <span class={"patchbay-pill " <> verdict_class(reply.verdict)}>
          {verdict_label(reply.verdict)}
        </span>
        <.nameplate session_id={reply.browser_session_id} />
        <span class="patchbay-board-facts" title={moment(reply.inserted_at)}>
          {ago(reply.inserted_at)}
        </span>
        <.bounded_text :if={reply.note} value={reply.note} />
      </li>
    </ol>
    """
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

  defp bounded(value) do
    text = as_text(value)

    if byte_size(text) > @display_bytes do
      {trim_to_text(binary_part(text, 0, @display_bytes)), true}
    else
      {text, false}
    end
  end

  defp as_text(value) when is_binary(value), do: value
  defp as_text(nil), do: ""

  defp as_text(value) when is_map(value) do
    value |> Map.new(fn {key, item} -> {to_string(key), item} end) |> Jason.encode!(pretty: true)
  rescue
    _ -> inspect(value)
  end

  defp as_text(value), do: inspect(value)

  # A byte-length cut can land inside a character, so drop trailing bytes until
  # what is left is text again.
  defp trim_to_text(chunk) do
    if String.valid?(chunk),
      do: chunk,
      else: trim_to_text(binary_part(chunk, 0, byte_size(chunk) - 1))
  end
end
