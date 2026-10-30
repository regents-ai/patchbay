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
  alias Patchbay.Payments
  alias PatchbayWeb.Forum.ReplyCursor
  alias RegentPayments.USDC

  @sites 200
  @inventory_tools 20
  @priority_reports 20
  @ranked_posts 20
  @reports_per_version 10
  @replies_per_report 10
  @replies_per_page 100

  @site_loads [:tool_count, :report_count]
  @post_loads [
    :author,
    :person,
    :reply_count,
    :solved,
    :view_count,
    :thread_like_count,
    :bounty_open,
    :verified_paid_usdc_atomic,
    :post_kind,
    :site,
    tool: [:site]
  ]
  # A site's own page puts the site on its posts itself (`on_site/2`).
  @site_post_loads (@post_loads -- [:site, tool: [:site]]) ++ [:tool]
  # A post's own page puts its site on its tool itself (`fetch_report/1`).
  @report_loads (@post_loads -- [tool: [:site]]) ++
                  [:tool, :discussion_state, :jev_reading, :post_like_count, :picture_count]

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
  The sites and tools whose names match what a visitor typed into the front
  page's search, for the answers shown above the matching discussions. Fewer
  than two letters matches nothing.
  """
  @spec matches(String.t()) :: {:ok, %{sites: [Site.t()], tools: [Tool.t()]}} | {:error, term()}
  def matches(q) do
    text = String.trim(q)

    if String.length(text) >= 2 do
      with {:ok, sites} <- Forum.find_sites(text, load: [:tool_count, :report_count]),
           {:ok, tools} <- Forum.find_tools(text),
           do: {:ok, %{sites: sites, tools: tools}}
    else
      {:ok, %{sites: [], tools: []}}
    end
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

  @doc """
  The most popular sites, at the top of `/sites`: the catalog's featured
  surfaces, each read as the same site record as everywhere else.
  """
  @spec most_popular() :: {:ok, [Site.t()]} | {:error, term()}
  def most_popular do
    with {:ok, sites, _more?} <- list_directory() do
      by_origin = Map.new(sites, &{&1.origin, &1})

      {:ok,
       for surface <- Patchbay.Forum.Catalog.featured_surfaces(),
           site = by_origin[surface["origin"]],
           site do
         site
         |> Map.put(:display_name, surface["display_name"])
         |> Map.put(:screenshot_path, surface["screenshot_path"])
         |> Map.put(:homepage_tool_count, surface["homepage_tool_count"])
       end}
    end
  end

  @doc """
  The sites that offer agents WebMCP tools, at most `limit` of them: the
  search window's sites before anything is typed.
  """
  @spec list_showcase(pos_integer()) :: {:ok, [Site.t()], boolean()} | {:error, term()}
  def list_showcase(limit \\ @sites) do
    with {:ok, page} <- Forum.list_showcase(query: site_summary(), page: [limit: limit]),
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

  @doc """
  The site filed under a domain, if the board has one, with anything more a
  page shows loaded in the same read (the site page's status shows when its
  tools were last seen). A read that fails is raised, never taken for a site
  the board does not have.
  """
  @spec fetch_site(String.t(), list()) :: {:ok, Site.t()} | :error
  def fetch_site(origin, load \\ []) do
    case Forum.get_site_by_origin(origin, query: Ash.Query.load(site_summary(), load)) do
      {:ok, site} -> {:ok, site}
      {:error, %Ash.Error.Invalid{}} -> :error
      {:error, failure} -> raise failure
    end
  end

  @doc """
  The directory entry a name points to: a catalog slug first, then a domain,
  so `chrome` and `google.com` name the same Chrome row, and
  `developers.openai.com` names `openai.com`.
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
      {:error, %Ash.Error.Invalid{}} -> :error
      {:error, failure} -> raise failure
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

  @doc """
  Which of these tool names the site's list holds now. The names are the ones
  a check found on the site's page, so the read is as small as that list.
  """
  @spec listed(Site.t(), [String.t()]) :: MapSet.t(String.t())
  def listed(%Site{}, []), do: MapSet.new()

  def listed(%Site{} = site, names),
    do: site.id |> Forum.list_site_tools_named!(names) |> MapSet.new(& &1.name)

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
    |> Ash.Query.load([:author, :person, :site, replies: first_replies()])
  end

  @doc """
  One report, with its author and the tool and site it belongs to. An address
  that names no report, or one held out of sight, is `:error`; a read that
  failed is its error.
  """
  @spec fetch_report(String.t()) :: {:ok, Report.t()} | :error | {:error, term()}
  def fetch_report(id) do
    with {:ok, %{visibility: :published} = report} <-
           Forum.get_report(id, load: @report_loads),
         {:ok, report} <- Ash.load(report, parts(report)) do
      {:ok, report |> put_site(report.site) |> without_parts()}
    else
      # An address that names no report, or names one held out of sight, is
      # not on the board.
      {:ok, _held} -> :error
      {:error, %Ash.Error.Invalid{}} -> :error
      {:error, failure} -> {:error, failure}
    end
  end

  # Its likes, pictures and picked replies are read only when it has them;
  # `without_parts/1` gives the rest their empty value.
  defp parts(report) do
    [
      post_likes: report.post_like_count > 0 && [:author],
      # The pictures' places only; each image is read when it is served.
      pictures:
        report.picture_count > 0 &&
          Ash.Query.select(Patchbay.Forum.PostPicture, [:id, :position]),
      accepted_reply: report.accepted_reply_id && [:author],
      solution_reply:
        report.solution_reply_id && [:author, :worked_for_others, :last_worked_at]
    ]
    |> Enum.filter(fn {_part, load} -> load end)
  end

  defp without_parts(report) do
    Enum.reduce(
      [post_likes: [], pictures: [], accepted_reply: nil, solution_reply: nil],
      report,
      fn {part, empty}, report ->
        case Map.fetch!(report, part) do
          %Ash.NotLoaded{} -> Map.put(report, part, empty)
          _loaded -> report
        end
      end
    )
  end

  @doc """
  The newest threads whose asker has picked an answer, newest first, with
  the answer and its fix: the home page's solved list and the public feed of
  solved fixes read the same list. At most `limit`, and never more than a
  page of the feed holds.
  """
  @spec solved_fixes(pos_integer()) :: {:ok, [Report.t()]} | {:error, term()}
  def solved_fixes(limit) do
    {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{"scope" => "solved"})

    with {:ok, page} <-
           Forum.list_feed_reports(
             query: Patchbay.Forum.Feed.query(filters),
             page: [limit: limit],
             load: [:site, solution_reply: [:author, :worked_for_others, :last_worked_at]]
           ) do
      {:ok, page.results}
    end
  end

  @doc """
  Solved and open on a site: how many tools it offers and when one
  was last seen, then its solved and still-open questions, the newest three of
  each with how many there are in all. The site comes from
  `fetch_site(origin, [:tools_seen_at])`.
  """
  @spec site_standing(Site.t()) :: map()
  def site_standing(%Site{} = site) do
    %{
      tool_count: site.tool_count,
      tools_seen_at: site.tools_seen_at,
      solved: site_questions(site, "solved"),
      open: site_questions(site, "unanswered")
    }
  end

  defp site_questions(site, scope) do
    {:ok, filters} =
      PatchbayWeb.Forum.Discussions.filters(%{"site" => site.origin, "scope" => scope})

    page =
      Forum.list_feed_reports!(
        query: Patchbay.Forum.Feed.query(filters),
        page: [limit: 3, count: true]
      )

    %{count: page.count, threads: on_site(page.results, site)}
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
    |> Forum.list_ranked_threads_for_site(load: @site_post_loads, page: post_page(cursor))
    |> post_page_result()
    |> case do
      {:ok, posts, next} -> {:ok, on_site(posts, site), next}
      invalid -> invalid
    end
  end

  # Every post on a site's page is filed under that site, and so is any tool
  # it names, so the site the page already holds is put on each rather than
  # read again for every page.
  defp on_site(posts, site), do: Enum.map(posts, &put_site(&1, site))

  defp put_site(%Report{tool: %Tool{} = tool} = post, site),
    do: %{post | site: site, tool: %{tool | site: site}}

  defp put_site(%Report{} = post, site), do: %{post | site: site}

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

    # The count is read after the page: read with it, the page loses its order.
    with {:ok, page} <-
           Forum.list_replies_for_report(report.id,
             query: query,
             load: [:author, :person, likes: [:author]],
             page: paging
           ),
         {:ok, page} <- Ash.load(page, :worked_for_others) do
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
  it, so it is on screen with what came before it. A new reply has no marks
  yet, so it comes straight after the replies people have marked: the
  opening page, unless more of them than a page holds come first.

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
    |> Ash.Query.load([:author, :person, :worked_for_others])
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
      [] -> %{}
      ids -> ids |> Payments.earned_usdc_atomic_by_profile() |> formatted_tips()
    end
  end

  defp formatted_tips({:ok, earned}),
    do: Map.new(earned, fn {id, atomic} -> {id, USDC.format(atomic)} end)

  defp formatted_tips({:error, failure}), do: raise(failure)

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
      load: [:author, :person, tool: [:site]],
      page: [limit: @priority_reports]
    )
    |> Map.fetch!(:results)
  end
end
