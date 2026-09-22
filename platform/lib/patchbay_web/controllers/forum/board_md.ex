defmodule PatchbayWeb.Forum.BoardMD do
  @moduledoc """
  The public board as markdown: the same facts as the page, for a reader
  that asked for `text/markdown`. Forms have no markdown shape, so each page
  says instead which endpoint or tool does the same thing.
  """

  use PatchbayWeb, :md
  defdelegate environment_label(environment), to: PatchbayWeb.Forum.BoardHTML
  defdelegate discussion_empty(filters), to: PatchbayWeb.Forum.BoardHTML

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

    "- [#{line(post_title(post))}](/posts/#{post.id}) — #{facts}\n#{connector_context(post)}"
  end

  def connector_context(%{submission_transport: :mcp_agent} = report) do
    "Service/site: #{line(report.site.origin)}" <>
      if(report.tool, do: " · Tool: #{line(report.tool.name)}", else: "") <>
      " · Target interface: #{line(report.target_interface || "Not declared")}" <>
      " · Declared agent environment: #{line(report.agent_environment || "Not declared")} (unverified)" <>
      " · Submission channel: mcp_agent (server-recorded)\n"
  end

  def connector_context(_report), do: ""

  @doc "The posts of a listing, or the words for an empty one."
  def post_lines([], empty), do: "_#{empty}_"
  def post_lines(posts, _empty), do: Enum.map_join(posts, "\n", &post_line/1)
end
