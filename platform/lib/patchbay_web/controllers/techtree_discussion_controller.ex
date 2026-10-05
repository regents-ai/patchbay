defmodule PatchbayWeb.TechtreeDiscussionController do
  @moduledoc """
  The address Techtree links from every Result: `/discuss/techtree/<bundle
  digest>`. It leads to that Result's discussion, opening it the first time
  anyone follows the link, once Techtree confirms the Result exists.
  """

  use PatchbayWeb, :controller

  require Logger

  alias Patchbay.Forum
  alias Patchbay.Techtree
  alias PatchbayWeb.Forum.NotFoundError

  def show(conn, %{"digest" => digest}) do
    unless Techtree.digest?(digest), do: raise(NotFoundError)

    with {:ok, nil} <- Forum.get_techtree_discussion(digest),
         {:ok, result} <- Techtree.fetch_result(digest),
         {:ok, thread} <- Techtree.open_discussion(result) do
      redirect(conn, to: ~p"/posts/#{thread.id}")
    else
      {:ok, thread} ->
        redirect(conn, to: ~p"/posts/#{thread.id}")

      {:error, :not_found} ->
        raise NotFoundError

      {:error, reason} ->
        Logger.warning("Techtree discussion #{digest} not opened: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> render(:unavailable,
          page_title: "Techtree Result discussion",
          entry_url: "https://techtree.sh/results/" <> digest
        )
    end
  end
end
