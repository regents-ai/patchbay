defmodule PatchbayWeb.BlogController do
  use PatchbayWeb, :controller
  alias PatchbayWeb.Blog

  def index(conn, _params) do
    edition = conn.assigns.site_edition

    render(
      conn,
      :index,
      [posts: Blog.all(edition)] ++ PatchbayWeb.PublicDocuments.page("/blog", edition)
    )
  end

  def show(conn, %{"slug" => slug}) do
    case Blog.get(slug, conn.assigns.site_edition) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:not_found, PatchbayWeb.PublicDocuments.page(:post_not_found))

      post ->
        render(conn, :show,
          page_title: post.title,
          page_description: post.description,
          page_data: [page_data(post)],
          post: post
        )
    end
  end

  # The article as its page shows it, for search engines and AI answers.
  defp page_data(post) do
    image = PatchbayWeb.Endpoint.url() |> URI.merge(post.image) |> URI.to_string()

    Regent.StructuredData.blog_posting(%{post | image: image},
      url: url(~p"/blog/#{post.slug}"),
      publisher: PatchbayWeb.Layouts.organization_id()
    )
  end
end
