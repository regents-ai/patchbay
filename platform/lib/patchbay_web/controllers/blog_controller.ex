defmodule PatchbayWeb.BlogController do
  use PatchbayWeb, :controller
  alias PatchbayWeb.Blog

  def index(conn, _params),
    do: render(conn, :index, [posts: Blog.all()] ++ PatchbayWeb.PublicDocuments.page("/blog"))

  def show(conn, %{"slug" => slug}) do
    case Blog.get(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:not_found, PatchbayWeb.PublicDocuments.page(:post_not_found))

      post ->
        render(conn, :show,
          page_title: post.title,
          page_description: post.description,
          post: post
        )
    end
  end
end
