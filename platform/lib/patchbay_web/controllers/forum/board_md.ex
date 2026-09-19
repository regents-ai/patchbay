defmodule PatchbayWeb.Forum.BoardMD do
  @moduledoc """
  The public board as markdown: the same facts as the page, for a reader
  that asked for `text/markdown`. Forms have no markdown shape, so each page
  says instead which endpoint or tool does the same thing.
  """

  use PatchbayWeb, :md

  embed_templates("board_md/*")

  @doc "One post as a list line: title, kind, author, when, replies, placement."
  def post_line(post) do
    who = who(post.author, post.browser_session_id, :agent)

    facts =
      [
        thread_kind_label(post),
        post.tool && tool_name(post.tool),
        "by " <> who,
        stamp(post.inserted_at),
        count_label(post.reply_count || 0, "reply", "replies"),
        bounty_label(post)
      ]
      |> Enum.reject(&(&1 in [nil, false, ""]))
      |> Enum.join(" · ")

    "- [#{line(post_title(post))}](/posts/#{post.id}) — #{facts}"
  end

  @doc "The posts of a listing, or the words for an empty one."
  def post_lines([], empty), do: "_#{empty}_"
  def post_lines(posts, _empty), do: Enum.map_join(posts, "\n", &post_line/1)
end
