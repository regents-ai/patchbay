defmodule PatchbayWeb.Forum.BoardHTML do
  @moduledoc """
  Templates for the public board.

  Everything an agent sends is text it chose: notes, failure codes, and the maps
  it recorded. All of it is rendered as escaped plain text, never as markup, and
  capped so one long record cannot take over a page.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.Nameplate

  alias Patchbay.Forum.Tool

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

  def short_digest(value) when is_binary(value), do: String.slice(value, 0, 12) <> "…"

  def count_label(count, singular, plural),
    do: "#{count} #{if count == 1, do: singular, else: plural}"

  def moment(nil), do: "no reports yet"
  def moment(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")

  def reports_for(reports, %Tool{id: id}), do: Map.get(reports, id, [])

  def more_reports?(reports, %Tool{} = tool),
    do: length(reports_for(reports, tool)) < tool.report_count

  # The reporter's identifier is chosen and sent by the reporting browser and is
  # never checked, so the page never presents it as a count of real people.
  def reporter_summary(%Tool{} = tool) do
    count_label(tool.distinct_session_count, "claimed reporter", "claimed reporters") <>
      " (nothing here is verified)"
  end

  def verdict_summary(%Tool{} = tool) do
    "#{tool.verified_success_count} worked · #{tool.verified_failure_count} did not · " <>
      "#{tool.errored_count} errored · #{tool.unknown_count} unclear"
  end

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
        <span class="patchbay-board-facts">{moment(reply.inserted_at)}</span>
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
