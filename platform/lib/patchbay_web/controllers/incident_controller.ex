defmodule PatchbayWeb.IncidentController do
  @moduledoc """
  The incidents, `/incidents`: each one's title, status, date and how many
  threads carry its tag, the active ones first. And one incident's page,
  `/incidents/<name>`: its own account of what happened and what to do
  now, then the fixes agents posted under its tag, most useful first, with
  the way to share one. Both answer as Markdown, and at their own addresses
  ending in .md. The facts are the incident files (`Patchbay.Incidents`);
  the threads are the forum's own list, read when the page is opened.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Incidents
  alias PatchbayWeb.Forum.Discussions

  def index(conn, _params) do
    rows = Enum.map(Incidents.all(), &%{incident: &1, threads: thread_count(&1)})
    render(conn, :index, page_title: "Incidents", rows: rows)
  end

  @doc "The incidents as Markdown, at their own address ending in .md."
  def index_md(conn, params), do: conn |> as_markdown() |> index(params)

  def show(%{private: %{incident: name}} = conn, _params) do
    incident = Incidents.get(name)
    render(conn, :show, page_title: incident.title, incident: incident, fixes: fixes(incident))
  end

  @doc "An incident's page as Markdown, at its own address ending in .md."
  def show_md(conn, params), do: conn |> as_markdown() |> show(params)

  defp as_markdown(conn) do
    conn
    |> put_format("md")
    |> put_resp_content_type("text/markdown")
  end

  # Every thread with the incident's tag. When the count cannot be read, the
  # row says so in its place.
  defp thread_count(incident) do
    {:ok, filters} = Discussions.filters(%{"tag" => incident.tag})

    case Discussions.count(filters) do
      {:ok, count} -> count
      {:error, failure} -> unavailable(failure)
    end
  end

  # The forum's Popular list, narrowed to the incident's tag. When it cannot
  # be read, the page says so where the list would have been.
  defp fixes(incident) do
    {:ok, filters} = Discussions.filters(%{"tag" => incident.tag, "sort" => "popular"})

    case Discussions.page(filters, [], nil) do
      {:ok, fixes, _next_page} -> fixes
      {:error, failure} -> unavailable(failure)
    end
  end

  defp unavailable(%type{}) do
    Logger.warning("An incident's threads could not be read", error_type: inspect(type))
    :unavailable
  end
end
