defmodule PatchbayWeb.ErrorLinkController do
  @moduledoc """
  A lasting link for each of Regents' own errors, `/errors/<code>`, such as
  `/errors/not_signed_in`. The Regents command line and sites print it beside
  the error, and it leads to the post that explains that error and how to clear
  it. The post may move or be replaced; the printed link stays the same.

  Which post each code leads to is the one table, `:error_links` in
  `config/config.exs`: a code and a post id per line. A code with no post, or whose post is gone,
  is a missing page that offers a search for the code instead.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.PostAddress

  @doc "Every code with a post, and the id of the post it leads to."
  @spec links() :: %{String.t() => String.t()}
  def links, do: Application.fetch_env!(:patchbay, :error_links)

  def show(conn, %{"code" => code}) do
    with {:ok, id} <- Map.fetch(links(), code),
         {:ok, post} <- Board.fetch_report(id) do
      conn
      |> put_status(:moved_permanently)
      |> redirect(to: PostAddress.path(post))
    else
      :error ->
        conn
        |> put_status(:not_found)
        |> render(:unknown, [code: code] ++ PatchbayWeb.PublicDocuments.page(:unknown_error))
    end
  end
end
