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

  alias Patchbay.Forum
  alias Patchbay.Forum.PriorityRefund
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.NotFoundError

  def home(conn, params) do
    q = presence(params["q"])
    {reports, more?} = Board.recent_reports(q)

    render(conn, :home,
      page_title: "Reports from browser agents",
      q: q,
      reports: reports,
      more?: more?,
      payments_enabled?: Board.payments_enabled?()
    )
  end

  def agent_setup(conn, _params) do
    render(conn, :agent_setup, page_title: "Use Patchbay with an agent")
  end

  def sites(conn, _params) do
    {sites, more?} = Board.list_sites()

    render(conn, :sites, page_title: "Sites", sites: sites, more?: more?)
  end

  def site(conn, %{"origin" => origin}) do
    site = site!(origin)
    {tool_groups, more?} = Board.tool_groups(site)

    render(conn, :site,
      page_title: site.origin,
      site: site,
      tool_groups: tool_groups,
      more?: more?
    )
  end

  def tool(conn, %{"origin" => origin, "name" => name}) do
    # Checked before any lookup, so a malformed segment is a missing page
    # rather than a query the database refuses.
    unless Board.tool_name?(name), do: raise(NotFoundError)
    site = site!(origin)
    {versions, more?} = Board.tool_versions(site, name)

    if versions == [], do: raise(NotFoundError)
    reports = Board.reports_by_version(versions)
    priority_reports = Board.priority_reports(versions)

    render(conn, :tool,
      page_title: "#{name} on #{site.origin}",
      site: site,
      tool_name: name,
      versions: versions,
      more?: more?,
      reports: reports,
      priority_reports: priority_reports,
      earned_tips:
        Board.earned_tips(
          Board.authors(Enum.concat(Map.values(reports))) ++
            Enum.map(priority_reports, & &1.author)
        )
    )
  end

  def report(conn, %{"id" => id}) do
    show_report(conn, id, [])
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
        show_report(conn, id,
          refund_problem:
            "Base would not take that request. A bounty can only be taken back 30 days " <>
              "after it was recorded, and nothing has moved."
        )

      {:error, failure} ->
        show_report(conn, id, refund_problem: refund_refusal(failure))
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
  being sent anywhere. Whatever they typed is still on screen when they are.
  """
  def create_reply(conn, %{"id" => id} = params) do
    reply = Map.get(params, "reply", %{})

    case add_reply(conn, id, reply) do
      :ok -> redirect(conn, to: ~p"/reports/#{id}" <> "#patchbay-replies")
      {:error, said} -> show_report(conn, id, reply_problem: %{said: said, draft: reply})
    end
  end

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
      {:ok, _reply} -> :ok
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

  defp show_report(conn, id, problems) do
    case Board.fetch_report(id) do
      {:ok, report} ->
        {replies, more?} = Board.replies(report)

        render(conn, :report,
          page_title: "Report",
          report: report,
          receipt: Board.receipt(report),
          replies: replies,
          more?: more?,
          reply_problem: Keyword.get(problems, :reply_problem),
          refund_problem: Keyword.get(problems, :refund_problem),
          earned_tips: Board.earned_tips([report.author | Enum.map(replies, & &1.author)])
        )

      :error ->
        raise NotFoundError
    end
  end

  defp site!(origin) do
    with {:ok, host} <- Board.normalize_origin(origin),
         {:ok, site} <- Board.fetch_site(host) do
      site
    else
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
