defmodule PatchbayWeb.PostListLive do
  @moduledoc """
  The first page of a list of posts, kept current while it is open: the home
  page's Recent list of every post, a site's posts and a tool's posts.

  A post that starts published arrives at the top, and the list keeps its
  page's length, so the last row leaves as it does. A shown post's replies,
  likes and solved mark change in place, and a post moderation hides leaves.
  Every change comes as a notice that carries the row
  (`Patchbay.Forum.LivePost`), so the list reads nothing when one arrives.

  Drawn with the page, the list takes the posts the page already read; it
  reads its first page itself once when it joins.
  """
  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [post_row: 1, posts_empty: 1]

  alias Patchbay.Forum.LivePost
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Discussions

  @impl true
  def mount(_params, session, socket) do
    list = list(session)
    # Listening starts before the list is read, so no post falls between.
    if connected?(socket), do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, list.topic)
    {socket, posts} = socket |> assign(list: list) |> first_page(list)
    rows = Enum.map(posts, &LivePost.row/1)
    ids = Enum.map(rows, & &1.id)
    if connected?(socket), do: Enum.each(ids, &follow/1)

    {:ok,
     socket
     |> assign(ids: ids, empty: rows == [])
     |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
     |> stream(:posts, rows, limit: list.size), layout: false}
  end

  @impl true
  def handle_info(%{event: "posted", payload: row}, socket) do
    %{list: list, ids: ids} = socket.assigns

    if fits?(list, row) and row.id not in ids do
      follow(row.id)
      {kept, dropped} = Enum.split([row.id | ids], list.size)
      Enum.each(dropped, &unfollow/1)

      {:noreply,
       socket
       |> assign(ids: kept, empty: false)
       |> stream_insert(:posts, row, at: 0, limit: list.size)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{event: "changed", payload: %{thread: row}}, socket) do
    cond do
      row.id not in socket.assigns.ids ->
        {:noreply, socket}

      LivePost.published?(row) ->
        {:noreply, stream_insert(socket, :posts, row, update_only: true)}

      true ->
        unfollow(row.id)

        {:noreply,
         socket
         |> assign(ids: List.delete(socket.assigns.ids, row.id))
         |> stream_delete(:posts, row)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ol id={@list.id <> "-rows"} class="pb-feed-list" phx-update="stream" phx-hook="MotionArrivals">
      <.post_row
        :for={{id, post} <- @streams.posts}
        id={id}
        post={post}
        site_edition={@site_edition}
        earned_tips={@earned_tips}
        likes={@list.likes}
        live
      />
    </ol>
    <.posts_empty :if={@empty} empty={@list.empty} ask={@list.ask} offer_ask={@list.ask != nil} />
    """
  end

  defp list(%{"list" => "home"} = session),
    do: %{
      id: "pb-home-posts",
      kind: :home,
      size: Discussions.page_size(),
      likes: :post,
      topic: LivePost.posts_topic(),
      empty: session["empty"],
      ask: nil
    }

  defp list(%{"list" => "site"} = session),
    do: Map.merge(ranked(session), %{id: "pb-site-posts", kind: :site})

  defp list(%{"list" => "tool", "tool" => name} = session),
    do: Map.merge(ranked(session), %{id: "pb-tool-posts", kind: :tool, tool: name})

  defp ranked(%{"site_id" => site_id, "origin" => origin} = session),
    do: %{
      size: Board.ranked_page_size(),
      likes: :thread,
      topic: LivePost.site_topic(site_id),
      origin: origin,
      empty: session["empty"],
      ask: session["ask"]
    }

  # Drawn with the page, the list has the page's own posts and tips; joined,
  # it reads them once. Only the rows are kept, in the stream. The home page's
  # list names no tips.
  defp first_page(socket, %{kind: :home}) do
    socket = assign_new(socket, :reports, &home_posts/0)
    {assign(socket, reports: nil, earned_tips: %{}), socket.assigns.reports}
  end

  defp first_page(socket, list) do
    edition = socket.assigns.site_edition

    socket =
      socket
      |> assign_new(:posts, fn -> board_posts(list, edition) end)
      |> assign_new(:earned_tips, fn %{posts: posts} ->
        Board.earned_tips(Enum.map(posts, & &1.author), edition)
      end)

    {assign(socket, :posts, nil), socket.assigns.posts}
  end

  defp home_posts do
    {:ok, filters} = Discussions.filters(%{})
    {:ok, posts, _next} = Discussions.page(filters, [], nil)
    posts
  end

  defp board_posts(list, edition) do
    {:ok, site} = Board.fetch_site_ref(list.origin)

    {:ok, posts, _next} =
      case list do
        %{kind: :site} -> Board.site_threads(site, edition, nil)
        %{kind: :tool, tool: name} -> Board.ranked_posts(site, name, edition, nil)
      end

    posts
  end

  defp fits?(%{kind: :tool, tool: name}, row), do: name in row.tool_names
  defp fits?(_list, _row), do: true

  defp follow(id), do: :ok = Phoenix.PubSub.subscribe(Patchbay.PubSub, LivePost.post_topic(id))

  defp unfollow(id),
    do: :ok = Phoenix.PubSub.unsubscribe(Patchbay.PubSub, LivePost.post_topic(id))
end
