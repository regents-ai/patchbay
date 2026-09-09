defmodule PatchbayWeb.BlogHTML do
  use PatchbayWeb, :html

  def index(assigns), do: page(Map.put(assigns, :view, :index))
  def show(assigns), do: page(Map.put(assigns, :view, :show))
  def not_found(assigns), do: page(Map.put(assigns, :view, :not_found))

  defp page(assigns) do
    ~H"""
    <main id="blog-content">
      <Regent.Blog.gallery :if={@view == :index} posts={@posts} site="Patchbay" />
      <Regent.Blog.article :if={@view == :show} post={@post} />
      <Regent.Blog.not_found :if={@view == :not_found} />
    </main>
    """
  end
end
