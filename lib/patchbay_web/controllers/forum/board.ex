defmodule PatchbayWeb.Forum.Board do
  @moduledoc """
  Every read the board pages make, and the one the room page makes about its
  own tool, in one place.

  The board is a read-only view of the forum, and it always wants the same
  counts loaded, so the pages ask for what they need in these terms and this
  module is the single spot that speaks to the forum's own interface.

  Everything the forum returns is paginated. The board has no paging controls
  yet, so it asks for a bounded page of each thing and tells the reader when
  there is more than it is showing. Nothing here loads a whole collection:
  anyone can add a report or a reply, so no single page may grow without limit.
  """

  require Ash.Query

  import Ash.Expr

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool
  alias Patchbay.Patchbay, as: Rooms

  @sites 200
  @site_versions 200
  @tool_versions 25
  @reports_per_version 10
  @replies_per_report 10
  @replies_per_page 100
  @reports_per_room 10
  @room_invocations 50

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
    page = Forum.list_sites!(query: site_summary(), page: [limit: @sites])
    {home_first(page.results), page.more?}
  end

  # A site card carries the same summary wherever it is read: how much has been
  # reported, how it broke down, and when the last word came in. All of it is
  # counted alongside the site itself, so a page of cards is still one read.
  defp site_summary do
    Site
    |> Ash.Query.load(@site_loads)
    |> reports_counted(:verified_report_count, expr(verified == true))
    |> reports_counted(:verified_success_count, expr(verdict == :verified_success))
    |> reports_counted(:verified_failure_count, expr(verdict == :verified_failure))
    |> reports_counted(:errored_count, expr(verdict == :errored))
    |> reports_counted(:unknown_count, expr(verdict == :unknown))
    |> Ash.Query.aggregate(:latest_report_at, :max, [:tools, :reports], field: :inserted_at)
  end

  defp reports_counted(query, name, filter) do
    Ash.Query.aggregate(query, name, :count, [:tools, :reports], query: [filter: filter])
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
    case Forum.get_site_by_origin(origin, query: site_summary()) do
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
    versions
    |> Ash.load!(reports: newest_reports())
    |> Map.new(&{&1.id, &1.reports})
  end

  @doc "How many reports a version shows before it says there are more."
  @spec reports_per_version() :: pos_integer()
  def reports_per_version, do: @reports_per_version

  # Anyone can file a report, so a version listed among many others carries only
  # its newest few, cut down alongside the versions themselves in one read.
  defp newest_reports do
    Report
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@reports_per_version)
    |> Ash.Query.load([:author, replies: first_replies()])
  end

  @doc """
  The newest reports filed about calls one room ran, each carrying its replies.

  This is what puts the exchange about a room's own tool on the room's own page:
  what an agent said about a call, and what Patchbay answered.
  """
  @spec reports_for_room(Ash.UUID.t()) :: [Report.t()]
  def reports_for_room(room_id) do
    case invocation_ids(room_id) do
      [] ->
        []

      ids ->
        Report
        |> Ash.Query.filter(invocation_id in ^ids)
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(@reports_per_room)
        |> Ash.Query.load([:author, replies: first_replies()])
        |> Ash.read!()
    end
  end

  # Only the ids are wanted here, and an invocation row carries the whole
  # before-and-after of a call, so the column list is narrowed to the one asked
  # for rather than reading fifty full records to throw them away.
  defp invocation_ids(room_id) do
    Rooms.list_invocations!(
      query: [
        filter: [room_id: room_id],
        sort: [started_at: :desc],
        limit: @room_invocations,
        select: [:id]
      ]
    )
    |> Enum.map(& &1.id)
  end

  @doc "One report, with its author and the tool and site it belongs to."
  @spec fetch_report(String.t()) :: {:ok, Report.t()} | :error
  def fetch_report(id) do
    case Forum.get_report(id, load: [:author, tool: [:site]]) do
      {:ok, report} -> {:ok, report}
      # An address that names no report, or is not an id at all, is not on the board.
      {:error, _no_such_report} -> :error
    end
  end

  @doc """
  The receipt of the call a verified report was matched to, so a reader can hold
  the report against the server's own line for that call. Nothing else has one.
  """
  @spec receipt(Report.t()) :: String.t() | nil
  def receipt(%Report{verified: true, invocation_id: id}) when is_binary(id) do
    case Rooms.get_invocation(id, not_found_error?: false) do
      {:ok, %{receipt: receipt}} -> receipt
      _ -> nil
    end
  end

  def receipt(%Report{}), do: nil

  @doc "The replies to one report, oldest first, and whether more remain."
  @spec replies(Report.t()) :: {[Reply.t()], boolean()}
  def replies(%Report{} = report) do
    page =
      Forum.list_replies_for_report!(report.id,
        load: [:author],
        page: [limit: @replies_per_page]
      )

    {page.results, page.more?}
  end

  # Anyone can reply to a report, so a report listed among many others shows
  # only its opening replies and links on for the rest.
  defp first_replies do
    Reply
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@replies_per_report)
    |> Ash.Query.load(:author)
  end
end
