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
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.Site
  alias Patchbay.Forum.Tool
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Identity.Privy
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Payments
  alias PatchbayWeb.Forum.ReplyCursor
  alias RegentPayments.USDC

  @sites 200
  @popular_sites 6
  @newest_threads 12
  @inventory_tools 20
  @priority_reports 20
  @ranked_posts 20
  @reports_per_version 10
  @replies_per_report 10
  @replies_per_page 100
  @reports_per_room 10
  @room_invocations 50

  @site_loads [:tool_count, :report_count]
  @post_loads [
    :author,
    :reply_count,
    :bounty_open,
    :verified_paid_usdc_atomic,
    :post_kind,
    :site,
    tool: [:site]
  ]

  @tool_loads [
    :report_count,
    :distinct_session_count,
    :verified_success_count,
    :verified_failure_count,
    :errored_count,
    :unknown_count,
    :latest_report_at,
    :current?
  ]

  @doc """
  Whether this deployment can take a wallet payment: Privy is named and Base
  can be read, the same two gates the balance tool uses. The rail reads this
  from the page rather than guessing.
  """
  @spec payments_enabled?() :: boolean()
  def payments_enabled? do
    case Privy.app_id() do
      id when is_binary(id) and id != "" -> RegentPayments.Balance.configured?()
      _unset -> false
    end
  end

  @doc """
  The front page's gallery, busiest first: the directory's entries and the
  sites with WebMCP tools on record.
  """
  @spec popular_sites() :: {:ok, [Site.t()]} | {:error, term()}
  def popular_sites do
    with {:ok, page} <-
           Forum.list_gallery_sites(query: site_summary(), page: [limit: @popular_sites]),
         do: {:ok, page.results}
  end

  @doc """
  The sites and tools whose names match what a visitor typed into the front
  page's search, for the answers shown above the matching discussions. Fewer
  than two letters matches nothing.
  """
  @spec matches(String.t()) :: {:ok, %{sites: [Site.t()], tools: [Tool.t()]}} | {:error, term()}
  def matches(q) do
    case String.trim(q) do
      text when byte_size(text) >= 2 ->
        with {:ok, sites} <- Forum.find_sites(text, load: [:tool_count, :report_count]),
             {:ok, tools} <- Forum.find_tools(text),
             do: {:ok, %{sites: sites, tools: tools}}

      _too_short ->
        {:ok, %{sites: [], tools: []}}
    end
  end

  @doc "The newest threads on the board, every site, for the strip across the front page."
  @spec newest_threads() :: {:ok, [Report.t()]} | {:error, term()}
  def newest_threads do
    with {:ok, page} <-
           Forum.list_newest_reports(load: [:site, :tool], page: [limit: @newest_threads]),
         do: {:ok, page.results}
  end

  @doc """
  The public directory: catalogued WebMCP entries first, then any other site
  the board has seen. The catalog itself is written once, at boot.
  """
  @spec list_directory() :: {:ok, [Site.t()], boolean()} | {:error, term()}
  def list_directory do
    with {:ok, page} <- Forum.list_directory(query: site_summary(), page: [limit: @sites]),
         do: {:ok, page.results, page.more?}
  end

  # A site card carries the same summary wherever it is read: how much has been
  # reported, how it broke down, and when the last word came in. All of it is
  # counted alongside the site itself, so a page of cards is still one read.
  defp site_summary do
    Site
    |> Ash.Query.load(@site_loads)
    |> reports_counted(:verified_success_count, expr(verdict == :verified_success))
    |> reports_counted(:verified_failure_count, expr(verdict == :verified_failure))
    |> reports_counted(:errored_count, expr(verdict == :errored))
    |> reports_counted(:unknown_count, expr(verdict == :unknown))
    |> Ash.Query.aggregate(:latest_report_at, :max, :reports, field: :inserted_at)
  end

  defp reports_counted(query, name, filter) do
    Ash.Query.aggregate(query, name, :count, :reports, query: [filter: filter])
  end

  @doc "The site filed under a domain, if the board has one."
  @spec fetch_site(String.t()) :: {:ok, Site.t()} | :error
  def fetch_site(origin) do
    case Forum.get_site_by_origin(origin, query: site_summary()) do
      {:ok, site} -> {:ok, site}
      {:error, _no_such_site} -> :error
    end
  end

  @doc """
  The directory entry a public address names: a catalog slug first, then a
  domain, so `/sites/chrome` and `/sites/google.com` open the same Chrome row,
  and `/sites/developers.openai.com` opens `openai.com`.
  """
  @spec fetch_site_ref(String.t()) :: {:ok, Site.t()} | :error
  def fetch_site_ref(ref) when is_binary(ref) do
    if slug?(ref) do
      case fetch_slug(ref) do
        {:ok, site} -> {:ok, site}
        :error -> fetch_normalized_origin(ref)
      end
    else
      case fetch_normalized_origin(ref) do
        {:ok, site} -> {:ok, site}
        :error -> fetch_slug(ref)
      end
    end
  end

  def fetch_site_ref(_ref), do: :error

  defp fetch_normalized_origin(ref) do
    case Origin.normalize(ref) do
      {:ok, domain} -> fetch_site(domain)
      {:error, _not_a_site} -> :error
    end
  end

  defp fetch_slug(ref) do
    case Forum.get_site_by_slug(ref, query: site_summary()) do
      {:ok, site} -> {:ok, site}
      {:error, _no_such_slug} -> :error
    end
  end

  @slug ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  defp slug?(value), do: Regex.match?(@slug, value)

  @doc """
  One page of a site's tools, one row per name with its newest version, in
  name order, and the name the next page continues from.
  """
  @spec inventory(Site.t(), String.t() | nil) :: {[Tool.t()], String.t() | nil}
  def inventory(%Site{} = site, after_name \\ nil) do
    page =
      Forum.site_inventory!(site.id, %{after_name: after_name},
        load: @tool_loads,
        page: [limit: @inventory_tools]
      )

    {page.results, if(page.more?, do: List.last(page.results).name)}
  end

  @doc "Whether an address segment could name a tool at all; anything else is not on the board."
  @spec tool_name?(term()) :: boolean()
  def tool_name?(name), do: Patchbay.Forum.ToolName.valid?(name)

  def tool_history(%Site{} = site, name, cursor \\ nil) do
    PatchbayWeb.Forum.ToolHistory.page(site, name, cursor, 25, @tool_loads)
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
    |> Ash.Query.load([:author, :site, replies: first_replies()])
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
    case Forum.get_report(id,
           load:
             @post_loads ++
               [
                 :solution_cards,
                 :jev_reading,
                 :view_count,
                 :thread_like_count,
                 post_likes: [:author],
                 # The pictures' places only; each image is read when it is served.
                 pictures: Ash.Query.select(Patchbay.Forum.PostPicture, [:id, :position]),
                 accepted_reply: [:author],
                 solution_reply: [:author]
               ]
         ) do
      # An address that names no report, or names one held out of sight, is
      # not on the board.
      {:ok, %{visibility: :published} = report} -> {:ok, report}
      {:ok, _held} -> :error
      {:error, _no_such_report} -> :error
    end
  end

  @doc """
  One page of every thread about one named tool on a site — posts filed
  against any of its versions, however many, and questions that only name it
  — open bounties first, and the cursor of the page after it when there is
  one. The page is its own: it does not move with the version history.

  An open bounty means money recorded in escrow on Base and no accepted
  answer yet, so a post is never listed above another for money that has
  not arrived or has already been paid out.
  """
  @spec ranked_posts(Site.t(), String.t(), String.t() | nil) ::
          {:ok, [Report.t()], String.t() | nil} | {:error, :invalid_posts_cursor}
  def ranked_posts(%Site{} = site, name, cursor \\ nil) do
    site.id
    |> Forum.list_ranked_posts_for_tool(name, load: @post_loads, page: post_page(cursor))
    |> post_page_result()
  end

  @doc """
  One page of every published thread on a site — the questions that name no
  tool and the posts about any of its tools — open bounties first, and the
  cursor of the page after it when there is one.
  """
  @spec site_threads(Site.t(), String.t() | nil) ::
          {:ok, [Report.t()], String.t() | nil} | {:error, :invalid_posts_cursor}
  def site_threads(%Site{} = site, cursor \\ nil) do
    site.id
    |> Forum.list_ranked_threads_for_site(load: @post_loads, page: post_page(cursor))
    |> post_page_result()
  end

  defp post_page(nil), do: [limit: @ranked_posts]
  defp post_page(cursor), do: [limit: @ranked_posts, after: cursor]

  # A page of posts and the cursor that continues it. A cursor that names no
  # page — expired, edited, or made up — is said so, never shown as an empty
  # list.
  defp post_page_result({:ok, %{results: results, more?: more?}}) do
    {:ok, results, if(more?, do: List.last(results).__metadata__.keyset)}
  end

  defp post_page_result({:error, %Ash.Error.Invalid{errors: errors}}) do
    if Enum.any?(errors, &match?(%Ash.Error.Page.InvalidKeyset{}, &1)),
      do: {:error, :invalid_posts_cursor},
      else: raise(Ash.Error.Invalid, errors: errors)
  end

  defp post_page_result({:error, failure}), do: raise(failure)

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

  @doc """
  One page of the replies to a report, oldest first: the opening page, or the
  one that follows a continuation the board or the API handed out, with the
  continuation for the page after it when there is one.
  """
  @spec replies(Report.t(), String.t() | nil) ::
          {:ok, [Reply.t()], String.t() | nil} | {:error, term()}
  def replies(%Report{} = report, keyset \\ nil, filter \\ "all") do
    paging =
      if keyset,
        do: [limit: @replies_per_page, after: keyset],
        else: [limit: @replies_per_page]

    query =
      case filter do
        "solution" -> [filter: [id: report.solution_reply_id]]
        "official" -> [filter: [owner_response: true]]
        _ -> []
      end

    with {:ok, page} <-
           Forum.list_replies_for_report(report.id,
             query: query,
             load: [:author, likes: [:author]],
             page: paging
           ) do
      {:ok, page.results, continuation(report, page)}
    end
  end

  @doc """
  Records that this reader opened the thread. The reader is the signed-in
  profile, or the page's forum session when nobody is signed in, so the same
  reader is counted once however often the page loads.
  """
  @spec record_view(Report.t(), map()) :: :ok
  def record_view(%Report{} = report, %{current_profile: profile, forum_session_id: session_id}) do
    viewer =
      if profile, do: Principal.for_profile(profile.id), else: Principal.for_session(session_id)

    Forum.record_thread_view!(report.id, viewer)
    :ok
  end

  @doc """
  What the signed-in reader has liked among the posts on screen: the ids of
  the replies, and `nil` for the opening post. Nobody signed in has liked
  nothing.
  """
  @spec liked(Report.t(), [Reply.t()], AgentProfile.t() | nil) :: MapSet.t()
  def liked(%Report{}, _replies, nil), do: MapSet.new()

  def liked(%Report{} = report, replies, profile) do
    [report.post_likes | Enum.map(replies, & &1.likes)]
    |> List.flatten()
    |> Enum.filter(&(&1.author_profile_id == profile.id))
    |> MapSet.new(& &1.reply_id)
  end

  defp continuation(report, %{more?: true, results: [_first | _rest] = results}) do
    ReplyCursor.sign(report.id, List.last(results).__metadata__.keyset)
  end

  defp continuation(_report, _page), do: nil

  @doc """
  Where a reader who has just posted a reply lands: the page that ends on
  it, so it is on screen with what came before it. A reply is the newest on
  its thread when it is posted, so this is the opening page only while the
  thread is short.

  The reply is already saved by the time this is asked, so a read that fails
  here, or that cannot find the reply, is an error about the landing page
  only, never about the post.
  """
  @spec page_ending_at(Reply.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def page_ending_at(%Reply{} = reply) do
    with {:ok, %{results: placed}} <-
           Forum.list_replies_for_report(reply.report_id,
             query: [filter: [id: reply.id]],
             page: [limit: 1]
           ),
         {:ok, %{__metadata__: %{keyset: keyset}}} <- placed_reply(placed),
         {:ok, %{results: earlier}} <-
           Forum.list_replies_for_report(reply.report_id,
             page: [before: keyset, limit: @replies_per_page]
           ) do
      {:ok, page_start(reply.report_id, earlier)}
    end
  end

  defp placed_reply([placed]), do: {:ok, placed}
  defp placed_reply(_missing), do: {:error, :reply_not_read}

  # A page holds @replies_per_page replies after its continuation, so the
  # page that ends on a reply starts just past the reply that many back.
  defp page_start(report_id, [anchor | _rest] = earlier)
       when length(earlier) == @replies_per_page do
    ReplyCursor.sign(report_id, anchor.__metadata__.keyset)
  end

  defp page_start(_report_id, _fewer), do: nil

  # Anyone can reply to a report, so a report listed among many others shows
  # only its opening replies and links on for the rest.
  defp first_replies do
    Reply
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(@replies_per_report)
    |> Ash.Query.load(:author)
  end

  @doc "Every author shown on a page of reports and their loaded replies, signed in or not."
  @spec authors([Report.t()]) :: [AgentProfile.t() | nil]
  def authors(reports) do
    Enum.flat_map(reports, fn report ->
      [report.author | Enum.map(report.replies, & &1.author)]
    end)
  end

  @doc """
  What the signed-in authors among the given ones have earned in tips, as
  formatted USDC keyed by profile id, leaving out anyone who has earned
  nothing. A page collects every author it shows and asks once, so however
  many reports and replies it lists this is one read, and a page with no
  signed-in author on it makes none.
  """
  @spec earned_tips([AgentProfile.t() | nil]) :: %{optional(Ash.UUID.t()) => String.t()}
  def earned_tips(authors) do
    case authors |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        {:ok, earned} = Payments.earned_usdc_atomic_by_profile(ids)
        Map.new(earned, fn {id, atomic} -> {id, USDC.format(atomic)} end)
    end
  end

  @doc """
  The paid priority reports about any version of one tool, newest first: the
  ones an asker has put money behind, listed on their own so a reader can see
  what is worth answering.
  """
  @spec priority_reports([Tool.t()]) :: [Report.t()]
  def priority_reports(versions) do
    versions
    |> Enum.map(& &1.id)
    |> Forum.list_priority_reports_for_tools!(
      load: [:author, tool: [:site]],
      page: [limit: @priority_reports]
    )
    |> Map.fetch!(:results)
  end
end
