defmodule PatchbayWeb.IncidentController do
  @moduledoc """
  The incidents, `/incidents`: each one's title, status, the day its sources
  were last read and how many replies its discussion has, the active ones
  first. It also answers as Markdown, at its own address ending in .md. The
  facts are the incident files (`Patchbay.Incidents`). Each incident's own
  page is its discussion, a post like any other
  (`PatchbayWeb.Forum.BoardController.incident/2`).

  Under them, the posts copied from cve.now's critical records
  (`Patchbay.Incidents.CveNow`), newest first, 25 a page. The first page
  is `/incidents` itself and each older one is `?page=N`, N written in plain
  digits from 2; any other value, or a page past the last, names no page.
  The incidents are listed on the first page only.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Forum
  alias Patchbay.Incidents
  alias Patchbay.Incidents.Discussion

  @per_page 25

  def index(conn, params) do
    number = page_number!(params)

    conn
    |> merge_assigns(head(number))
    |> render(:index,
      incidents: Incidents.all(),
      replies: replies(),
      page: number,
      cves: cves!(number)
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

  # One page of the copied posts, or `:unavailable` when they cannot be read,
  # which the list says in its place.
  defp cves!(number) do
    case Forum.list_cve_now_posts(
           page: [limit: @per_page, offset: (number - 1) * @per_page, count: true],
           load: [:reply_count]
         ) do
      {:ok, %{results: []}} when number > 1 ->
        raise PatchbayWeb.Forum.NotFoundError

      {:ok, %{results: posts, count: count}} ->
        %{posts: posts, pages: max(div(count + @per_page - 1, @per_page), 1)}

      {:error, %type{}} ->
        Logger.warning("Copied cve.now posts could not be read", error_type: inspect(type))
        :unavailable
    end
  end

  defp head(1), do: PatchbayWeb.PublicDocuments.page("/incidents")
  defp head(number), do: PatchbayWeb.PublicDocuments.incidents_page(number)

  defp page_number!(%{"page" => page}) when is_binary(page) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, page) and page != "1",
      do: String.to_integer(page),
      else: raise(PatchbayWeb.Forum.NotFoundError)
  end

  defp page_number!(%{"page" => _not_plain_digits}), do: raise(PatchbayWeb.Forum.NotFoundError)
  defp page_number!(_first_page), do: 1
end
