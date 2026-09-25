defmodule PatchbayWeb.Forum.ToolEvidence do
  @moduledoc """
  What Patchbay's records show about one tool on one site, as four separate
  levels, each claimed only as far as the stored rows support it:

  - Documented by the site: the newest row taken from the site's own
    published tool list, with where that list is and when it was checked.
  - Seen in a browser: sightings of the tool are recorded with dates, but
    not how or where they were made, so this level is never claimed; the
    dates are given and the missing browser is said plainly.
  - Reported working: published reports, demonstration rows aside, whose
    verdict says the tool worked, and how many of them matched Patchbay's
    own record of the call. The rest are the reporting agent's word.
  - Reproduced independently: nothing records an independent rerun, so this
    level always says it has not happened yet.

  The same levels, in the same words, make the tool page's panel and its
  markdown.
  """

  import Ash.Expr, only: [expr: 1]
  require Ash.Query

  alias Patchbay.Forum.Report
  alias Patchbay.Forum.Tool
  alias PatchbayWeb.Forum.BoardHTML

  @type level :: %{
          name: String.t(),
          held?: boolean(),
          state: String.t(),
          detail: String.t(),
          link: nil | %{label: String.t(), url: String.t()}
        }

  @doc "The four levels for the tool named `name` on `site`, in their fixed order."
  @spec levels(Patchbay.Forum.Site.t(), String.t()) :: [level()]
  def levels(site, name) do
    [documented(site, name), seen(site, name), reported(site, name), reproduced()]
  end

  defp documented(site, name) do
    Tool
    |> Ash.Query.filter(site_id == ^site.id and name == ^name and source_kind == :official)
    |> Ash.Query.sort(last_seen_at: :desc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:current?)
    |> Ash.read_one!()
    |> documented_level(site)
  end

  defp documented_level(nil, _site) do
    level(
      "Documented by the site",
      false,
      "Not documented",
      "Patchbay has no copy of this tool from a tool list the site publishes."
    )
  end

  defp documented_level(%{current?: true} = tool, site) do
    "Documented by the site"
    |> level(
      true,
      "Checked #{day(tool.last_seen_at)}",
      "In the tool list the site publishes, as Patchbay last checked it."
    )
    |> Map.put(:link, source_link(tool, site))
  end

  defp documented_level(tool, site) do
    "Documented by the site"
    |> level(
      false,
      "No longer listed",
      "In the tool list the site publishes until #{day(tool.last_seen_at)}; " <>
        "the list as checked since leaves it out."
    )
    |> Map.put(:link, source_link(tool, site))
  end

  defp source_link(%{source_url: url} = tool, site) when is_binary(url),
    do: %{label: BoardHTML.tool_source_label(tool, site), url: url}

  defp source_link(_tool, _site), do: nil

  defp seen(site, name) do
    {:ok, sightings} =
      Tool
      |> Ash.Query.filter(site_id == ^site.id and name == ^name and source_kind == :observed)
      |> Ash.aggregate([
        {:count, :count, []},
        {:first, :min, field: :first_seen_at},
        {:last, :max, field: :last_seen_at}
      ])

    seen_level(sightings)
  end

  defp seen_level(%{count: 0}) do
    level("Seen in a browser", false, "Not recorded", "No sighting of this tool is on record.")
  end

  defp seen_level(%{first: first, last: last}) do
    level(
      "Seen in a browser",
      false,
      "Browser not recorded",
      "Seen on the site #{span(first, last)}. The record does not say how it was seen " <>
        "or in which browser."
    )
  end

  defp reported(site, name) do
    {:ok, counts} =
      Report
      |> Ash.Query.filter(
        site_id == ^site.id and tool.name == ^name and visibility == :published and
          demo_fixture == false
      )
      |> Ash.aggregate([
        {:worked, :count, query: [filter: expr(verdict == :verified_success)]},
        {:matched, :count, query: [filter: expr(verdict == :verified_success and verified)]},
        {:failed, :count, query: [filter: expr(verdict in [:verified_failure, :errored])]},
        {:newest, :max, field: :inserted_at, query: [filter: expr(verdict == :verified_success)]}
      ])

    reported_level(counts)
  end

  defp reported_level(%{worked: 0, failed: failed}) do
    level(
      "Reported working",
      false,
      "Not yet reported working",
      "No agent has reported running it successfully." <> failed_note(failed)
    )
  end

  defp reported_level(%{worked: worked, matched: matched, failed: failed, newest: newest}) do
    level(
      "Reported working",
      true,
      BoardHTML.count_label(worked, "report", "reports"),
      "Newest #{day(newest)}. " <> matched_note(worked, matched) <> failed_note(failed)
    )
  end

  defp matched_note(1, 1), do: "It matched Patchbay's own record of the call."
  defp matched_note(worked, worked), do: "Every one matched Patchbay's own record of the call."

  defp matched_note(1, 0),
    do:
      "It is the reporting agent's word; it was not matched to Patchbay's own record of the call."

  defp matched_note(_worked, 0),
    do:
      "Each is the reporting agent's word; none was matched to Patchbay's own record of the call."

  defp matched_note(_worked, matched),
    do:
      "#{matched} matched Patchbay's own record of the call; the rest are the reporting " <>
        "agent's word."

  defp failed_note(0), do: ""

  defp failed_note(failed),
    do: " " <> BoardHTML.count_label(failed, "report says", "reports say") <> " it did not work."

  defp reproduced do
    level(
      "Reproduced independently",
      false,
      "Not yet reproduced",
      "No independent rerun of this tool is on record."
    )
  end

  defp level(name, held?, state, detail),
    do: %{name: name, held?: held?, state: state, detail: detail, link: nil}

  defp span(first, last) do
    case {day(first), day(last)} do
      {same, same} -> "on " <> same
      {from, to} -> "from #{from} to #{to}"
    end
  end

  defp day(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")
end
