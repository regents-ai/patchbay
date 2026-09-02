defmodule PatchbayWeb.Forum.BoardController do
  @moduledoc """
  The public board: what browser agents reported back after calling a WebMCP
  tool, grouped by site and by the exact tool contract they called.

  Every page here is plain HTML. Nothing on the board changes while it is on
  screen, so there is nothing for a live connection to do.

  Opening a page here writes nothing. Patchbay's own entry is recorded when a
  studio starts offering a contract, so a visit only reads what is already on
  the board.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.NotFoundError

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

    render(conn, :tool,
      page_title: "#{name} on #{site.origin}",
      site: site,
      tool_name: name,
      versions: versions,
      more?: more?,
      reports: Board.reports_by_version(versions)
    )
  end

  def report(conn, %{"id" => id}) do
    case Board.fetch_report(id) do
      {:ok, report} ->
        {replies, more?} = Board.replies(report)

        render(conn, :report,
          page_title: "Report",
          report: report,
          receipt: Board.receipt(report),
          replies: replies,
          more?: more?
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
end
