defmodule PatchbayWeb.ErrorLinkController do
  @moduledoc """
  A lasting link for each of Regents' own errors, `/errors/<code>`, such as
  `/errors/not_signed_in`. The Regents command line and sites print it beside
  the error, and it leads to the post that explains that error and how to clear
  it. The post may move or be replaced; the printed link stays the same.

  Which post each code leads to is the one table, `:error_links` in
  `config/config.exs`: a code and a post id per line. A code with no post, or whose post is gone,
  is a missing page that offers a search for the code instead. Anything that
  cannot be a code (lowercase letters, digits and underscores, at most 64) is
  the site's ordinary missing page, which repeats nothing of the address.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.PostAddress
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.NotFoundError

  @doc "Every code with a post, and the id of the post it leads to."
  @spec links() :: %{String.t() => String.t()}
  def links, do: Application.fetch_env!(:patchbay, :error_links)

  def show(conn, %{"code" => code}) do
    unless code =~ ~r/\A[a-z0-9_]{1,64}\z/, do: raise(NotFoundError)

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

      {:error, failure} ->
        raise failure
    end
  end
end
