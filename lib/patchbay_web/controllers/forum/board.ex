defmodule PatchbayWeb.Forum.Board do
  @moduledoc """
  Every read the board pages make, in one place.

  The board is a read-only view of the forum, and it always wants the same
  counts loaded, so the pages ask for what they need in these terms and this
  module is the single spot that speaks to the forum's own interface.

  Everything the forum returns is paginated. The board has no paging controls
  yet, so it asks for a bounded page of each thing and tells the reader when
  there is more than it is showing. Nothing here loads a whole collection:
  anyone can add a report or a reply, so no single page may grow without limit.
  """

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool

  @sites 200
  @site_versions 200
  @tool_versions 25
  @reports_per_version 10
  @replies_per_report 10
  @replies_per_page 100

  @site_loads [:tool_count, :report_count]

  @tool_loads [
    :report_count,
    :distinct_session_count,
    :verified_success_count,
    :verified_failure_count,
    :errored_count,
    :unknown_count,
    :latest_report_at
  ]

  @doc "The busiest sites on the board, Patchbay's own first, and whether more remain."
  @spec list_sites() :: {[Site.t()], boolean()}
  def list_sites do
    page = Forum.list_sites!(query: [load: @site_loads], page: [limit: @sites])
    {home_first(page.results), page.more?}
  end

  # Patchbay's own board is the one a visitor is standing on, so it leads the
  # list however busy the others are.
  defp home_first(sites) do
    home = RoomMirror.origin()
    {ours, theirs} = Enum.split_with(sites, &(&1.origin == home))
    ours ++ theirs
  end

  @doc "The one host an address names, if it names a host at all."
  @spec normalize_origin(String.t()) :: {:ok, String.t()} | :error
  def normalize_origin(origin) do
    case Origin.normalize(origin) do
      {:ok, host} -> {:ok, host}
      {:error, _not_a_host} -> :error
    end
  end

  @doc "The site a host names, if the board has one."
  @spec fetch_site(String.t()) :: {:ok, Site.t()} | :error
  def fetch_site(origin) do
    case Forum.get_site_by_origin(origin, load: @site_loads) do
      {:ok, site} -> {:ok, site}
      {:error, _no_such_site} -> :error
    end
  end

  @doc """
  Every tool version on a site, grouped so one tool's versions stay together,
  and whether more remain.
  """
  @spec tool_groups(Site.t()) :: {[[Tool.t()]], boolean()}
  def tool_groups(%Site{} = site) do
    page = tool_page(site, [], @site_versions)
    {Enum.chunk_by(page.results, & &1.name), page.more?}
  end

  @tool_name ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @doc "Whether an address segment could name a tool at all; anything else is not on the board."
  @spec tool_name?(term()) :: boolean()
  def tool_name?(name), do: is_binary(name) and Regex.match?(@tool_name, name)

  @doc """
  The most recently seen versions of one named tool on a site, newest first,
  and whether the tool has more versions than that.
  """
  @spec tool_versions(Site.t(), String.t()) :: {[Tool.t()], boolean()}
  def tool_versions(%Site{} = site, name) do
    page = tool_page(site, [filter: [name: name]], @tool_versions)
    {page.results, page.more?}
  end

  defp tool_page(%Site{} = site, query, limit) do
    Forum.list_tools_for_site!(site.id,
      query: Keyword.put(query, :load, @tool_loads),
      page: [limit: limit]
    )
  end

  @doc """
  The newest reports filed against each of the given tool versions, keyed by
  version, each carrying its first few replies.
  """
  @spec reports_by_version([Tool.t()]) :: %{optional(Ash.UUID.t()) => [Report.t()]}
  def reports_by_version(versions) do
    Map.new(versions, fn version ->
      page =
        Forum.list_reports_for_tool!(version.id,
          query: [load: [replies: first_replies()]],
          page: [limit: @reports_per_version]
        )

      {version.id, page.results}
    end)
  end

  @doc "One report, with the tool and site it belongs to."
  @spec fetch_report(String.t()) :: {:ok, Report.t()} | :error
  def fetch_report(id) do
    case Forum.get_report(id, load: [tool: [:site]]) do
      {:ok, report} -> {:ok, report}
      # An address that names no report, or is not an id at all, is not on the board.
      {:error, _no_such_report} -> :error
    end
  end

  @doc "The replies to one report, oldest first, and whether more remain."
  @spec replies(Report.t()) :: {[Reply.t()], boolean()}
  def replies(%Report{} = report) do
    page = Forum.list_replies_for_report!(report.id, page: [limit: @replies_per_page])
    {page.results, page.more?}
  end

  # Anyone can reply to a report, so a report listed among many others shows
  # only its opening replies and links on for the rest.
  defp first_replies do
    Reply
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@replies_per_report)
  end
end
