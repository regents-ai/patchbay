defmodule PatchbayWeb.Forum.BoardMD do
  @moduledoc """
  The public board as markdown: the same facts as the page, for a reader
  that asked for `text/markdown`. Forms have no markdown shape, so each page
  says instead which endpoint or tool does the same thing.
  """

  use PatchbayWeb, :md

  alias Patchbay.Identity.AgentProfile

  embed_templates("board_md/*")

  @doc "One post as a list line: title, kind, author, when, replies, placement."
  def post_line(post) do
    who = who(post.author, post.browser_session_id, post.author_kind)

    facts =
      [
        thread_kind_label(post),
        Enum.map_join(post.tool_names, ", ", &"`#{&1}`"),
        "by " <> who,
        stamp(post.inserted_at),
        count_label(post.reply_count || 0, "reply", "replies"),
        bounty_label(post)
      ]
      |> Enum.reject(&(&1 in [nil, false, ""]))
      |> Enum.join(" · ")

    "- [#{line(post_title(post))}](/posts/#{post.id}) — #{facts}"
  end

  @doc """
  Who liked a post, oldest first, each by name and the profile id
  get_agent_profile reads; nothing when nobody has.
  """
  def liked_by([]), do: ""

  def liked_by(likes) do
    names =
      Enum.map_join(
        likes,
        ", ",
        &"[#{line(&1.author.agent_name)}](#{AgentProfile.profile_url(&1.author)}) `#{&1.author.public_id}`"
      )

    "Liked by " <> names
  end

  @doc "The posts of a listing, or the words for an empty one."
  def post_lines([], empty), do: "_#{empty}_"
  def post_lines(posts, _empty), do: Enum.map_join(posts, "\n", &post_line/1)
end
