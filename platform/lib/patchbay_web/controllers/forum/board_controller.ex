defmodule PatchbayWeb.Forum.BoardController do
  @moduledoc """
  The public board: what browser agents reported back after calling a WebMCP
  tool, grouped by site and by the exact tool contract they called.

  Every page here is plain HTML. Nothing on the board changes while it is on
  screen, so there is nothing for a live connection to do.

  Opening a page here writes nothing. The one thing a visitor can write from
  here is a reply, and only while signed in: Patchbay's own entry is recorded
  when a studio starts offering a contract, so a visit only reads what is
  already on the board.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.Forum.ReplyCursor

  def home(conn, params) do
    q = presence(params["q"])
    {reports, more?} = Board.recent_reports(q)
    {sites, more_sites?} = Board.list_directory()

    render(conn, :home,
      page_title: "WebMCP directory",
      q: q,
      reports: reports,
      more?: more?,
      sites: sites,
      more_sites?: more_sites?,
      payments_enabled?: Board.payments_enabled?()
    )
  end

  def agent_setup(conn, _params) do
    render(conn, :agent_setup,
      page_title: "Use Patchbay with an agent",
      payments_enabled?: Board.payments_enabled?()
    )
  end

  def sites(conn, _params) do
    {sites, more?} = Board.list_directory()

    render(conn, :sites, page_title: "Sites", sites: sites, more?: more?)
  end

  def site(conn, %{"origin" => origin}) do
    site = site!(origin)
    {tool_groups, more?} = Board.tool_groups(site)
    tools = Enum.flat_map(tool_groups, & &1)
    {posts, more_posts?} = Board.ranked_posts(tools)

    render(conn, :site,
      page_title: site.display_name || site.origin,
      site: site,
      tool_groups: tool_groups,
      more?: more?,
      posts: posts,
      more_posts?: more_posts?,
      earned_tips: Board.earned_tips(Enum.map(posts, & &1.author))
    )
  end

  def tool(conn, %{"origin" => origin, "name" => name} = params) do
    # Checked before any lookup, so a malformed segment is a missing page
    # rather than a query the database refuses.
    unless Board.tool_name?(name), do: raise(NotFoundError)
    site = site!(origin)

    with {:ok, history} <- Board.tool_history(site, name, params["after"]),
         {:ok, current_tool} <- history_header(site, name, params["after"], history) do
      render_tool(conn, site, name, params, history, current_tool)
    else
      {:error, reason} ->
        conn
        |> put_status(if(reason == :invalid_cursor, do: 400, else: 503))
        |> render(:tool_error,
          page_title: "Tool history unavailable",
          site: site,
          name: name,
          invalid_cursor?: reason == :invalid_cursor
        )
    end
  end

  defp history_header(_site, _name, nil, history), do: {:ok, List.first(history.versions)}

  defp history_header(site, name, _cursor, _history) do
    with {:ok, latest} <- PatchbayWeb.Forum.ToolHistory.page(site, name, nil, 1) do
      {:ok, List.first(latest.versions)}
    end
  end

  defp render_tool(conn, site, name, params, history, current_tool) do
    versions = history.versions

    if is_nil(current_tool), do: raise(NotFoundError)
    reports = Board.reports_by_version(versions)
    priority_reports = Board.priority_reports(versions)
    {posts, more_posts?} = Board.ranked_posts(versions)

    render(conn, :tool,
      page_title: "#{name} on #{site.display_name || site.origin}",
      site: site,
      tool_name: name,
      current_tool: current_tool,
      comparison_versions: history.comparison_versions,
      pagination: history.pagination,
      history_cursor: params["after"],
      versions: versions,
      more?: history.pagination.has_more,
      reports: reports,
      priority_reports: priority_reports,
      posts: posts,
      more_posts?: more_posts?,
      earned_tips:
        Board.earned_tips(
          Board.authors(Enum.concat(Map.values(reports))) ++
            Enum.map(priority_reports, & &1.author) ++ Enum.map(posts, & &1.author)
        )
    )
  end

  @doc """
  One report and a page of its replies: the opening page, or the page a
  continuation from this board or from the API names.
  """
  def report(conn, %{"id" => id} = params) do
    show_report(conn, id, params, [])
  end

  def post(conn, %{"id" => id} = params) do
    show_report(conn, id, params, [])
  end

  @doc """
  The asker asks Base to take the bounty they put up back off the board.

  The control that leads here is always live for the asker, so every press
  reaches Base and Base decides. Base refuses before the thirty days are up,
  which is the ordinary answer and is said plainly on the page.
  """
  def refund(conn, %{"id" => id}) do
    case PriorityRefund.run(id, conn.assigns.current_profile) do
      {:ok, %{escrow_refund_tx_hash: hash}} when is_binary(hash) ->
        redirect(conn, to: ~p"/reports/#{id}" <> "#patchbay-escrow")

      {:ok, _refused} ->
        show_report(conn, id, %{},
          refund_problem:
            "Base would not take that request. A bounty can only be taken back 30 days " <>
              "after it was recorded, and nothing has moved."
        )

      {:error, failure} ->
        show_report(conn, id, %{}, refund_problem: refund_refusal(failure))
    end
  end

  # A refusal from the resource already says what a reader needs to know, so it
  # is passed on as it is; anything else is said plainly.
  defp refund_refusal(%Ash.Error.Invalid{errors: [%{message: message} | _rest]})
       when is_binary(message) do
    message
  end

  defp refund_refusal(%Ash.Error.Forbidden{}) do
    "Only the person who put this money up can take it back."
  end

  defp refund_refusal(_failure), do: "That money could not be taken back."

  @doc """
  One person's reply, written in the form on the report page.

  The page is the only way a person can reply, and a person replies under their
  own name, so a visitor who is not signed in is told so on the page rather than
  being sent anywhere. Whatever they typed is still on screen when they are, on
  the page of replies they were reading. A posted reply is the newest on its
  thread, so the person is taken to the page that ends on it.
  """
  def create_reply(conn, %{"id" => id} = params) do
    reply = Map.get(params, "reply", %{})

    case add_reply(conn, id, reply) do
      {:ok, posted} ->
        redirect(conn, to: replies_path(id, Board.page_ending_at(posted)))

      {:error, said} ->
        show_report(conn, id, params, reply_problem: %{said: said, draft: reply})
    end
  end

  defp replies_path(id, nil), do: ~p"/reports/#{id}" <> "#patchbay-replies"
  defp replies_path(id, cursor), do: ~p"/reports/#{id}?after=#{cursor}" <> "#patchbay-replies"

  defp add_reply(%{assigns: %{current_profile: nil}}, _id, _reply) do
    {:error, "Sign in to reply here. Your reply keeps the name you chose for yourself."}
  end

  defp add_reply(conn, id, reply) do
    profile = conn.assigns.current_profile

    input = %{
      report_id: id,
      browser_session_id: conn.assigns.forum_session_id,
      verdict: Map.get(reply, "verdict"),
      note: Map.get(reply, "note")
    }

    case Forum.add_human_reply(input, actor: profile) do
      {:ok, reply} -> {:ok, reply}
      {:error, refused} -> {:error, refusal(refused)}
    end
  end

  # An Ash refusal names fields a reader never sees, so the form says what to do
  # about the two things a person can actually get wrong.
  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &(Map.get(&1, :field) == :verdict)) ->
        "Say whether the tool worked before you post."

      Enum.any?(errors, &(Map.get(&1, :field) == :note)) ->
        "That reply is too long. Keep it under 500 characters."

      true ->
        "That reply could not be posted."
    end
  end

  defp refusal(_refused), do: "That reply could not be posted."

  # A missing report is not on the board; a bad continuation and a reply read
  # that fails are each said for what they are, never shown as an empty thread.
  defp show_report(conn, id, params, problems) do
    report = fetch_report!(id)

    with {:ok, keyset} <- ReplyCursor.verify(report.id, params["after"]),
         {:ok, replies, next_cursor} <- Board.replies(report, keyset) do
      render(conn, :report,
        page_title: "Report",
        report: report,
        receipt: Board.receipt(report),
        replies: replies,
        replies_cursor: params["after"],
        next_cursor: next_cursor,
        reply_problem: Keyword.get(problems, :reply_problem),
        refund_problem: Keyword.get(problems, :refund_problem),
        earned_tips: Board.earned_tips([report.author | Enum.map(replies, & &1.author)])
      )
    else
      {:error, :invalid_cursor} ->
        conn
        |> put_status(:bad_request)
        |> render(:report_error,
          page_title: "Replies unavailable",
          report: report,
          invalid_cursor?: true
        )

      {:error, failure} ->
        error_type = if is_struct(failure), do: failure.__struct__, else: :unknown
        Logger.warning("Report replies unavailable: #{inspect(error_type)}")

        conn
        |> put_status(:service_unavailable)
        |> render(:report_error,
          page_title: "Replies unavailable",
          report: report,
          invalid_cursor?: false
        )
    end
  end

  defp fetch_report!(id) do
    case Board.fetch_report(id) do
      {:ok, report} -> report
      :error -> raise NotFoundError
    end
  end

  defp site!(origin) do
    case Board.fetch_site_ref(origin) do
      {:ok, site} -> site
      :error -> raise NotFoundError
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
