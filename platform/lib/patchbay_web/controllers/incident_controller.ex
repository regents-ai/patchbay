defmodule PatchbayWeb.IncidentController do
  @moduledoc """
  The incidents, `/incidents`: each one's title, status, the day its sources
  were last read and how many replies its discussion has, the active ones
  first. It also answers as Markdown, at its own address ending in .md. The
  facts are the incident files (`Patchbay.Incidents`). Each incident's own
  page is its discussion, a post like any other
  (`PatchbayWeb.Forum.BoardController.incident/2`).
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Incidents
  alias Patchbay.Incidents.Discussion

  def index(conn, _params) do
    render(
      conn,
      :index,
      [incidents: Incidents.all(), replies: replies()] ++
        PatchbayWeb.PublicDocuments.page("/incidents")
    )
  end

  @doc "The incidents as Markdown, at their own address ending in .md."
  def index_md(conn, params) do
    conn
    |> put_format("md")
    |> put_resp_content_type("text/markdown")
    |> index(params)
  end

  # When the counts cannot be read, each row says so in its place.
  defp replies do
    case Discussion.reply_counts() do
      {:ok, counts} ->
        counts

      {:error, %type{}} ->
        Logger.warning("Incident reply counts could not be read", error_type: inspect(type))
        :unavailable
    end
  end
end
