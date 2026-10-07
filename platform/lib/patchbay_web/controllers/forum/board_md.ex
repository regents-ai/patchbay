defmodule PatchbayWeb.Forum.BoardMD do
  @moduledoc """
  The public board as markdown: the same facts as the page, for a reader
  that asked for `text/markdown`. Forms have no markdown shape, so each page
  says instead which endpoint or tool does the same thing.
  """

  use PatchbayWeb, :md

  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Forum.SiteChecks

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

  @doc "What a site's check found, as markdown, or where the check stands."
  def check_lines(domain, check) do
    case SiteChecks.state(check) do
      :none -> "_Not checked yet._"
      :checking -> "_Checking #{domain} now. Read this page again in a minute._"
      :failed -> "_#{domain} could not be checked just now._"
      :done -> found_lines(domain, check)
    end
  end

  defp found_lines(domain, check) do
    findings = check.findings
    {from_site, related} = Enum.split_with(findings["code"], & &1["from_site"])

    [
      "Checked #{stamp(check.checked_at)}.",
      SiteChecks.nothing?(findings) && "_Nothing for agents found on #{domain}._",
      group("WebMCP tools on its page", findings["webmcp"], fn tool ->
        "`#{line(tool["name"])}`" <> note(tool["description"])
      end),
      group("MCP servers", findings["servers"], fn server ->
        names = Enum.map_join(server["tools"], ", ", &"`#{line(&1["name"])}`")
        "<#{server["url"]}> — #{SiteChecks.server_label(server)}" <> note(names)
      end),
      group("Files for agents", findings["files"], fn file ->
        "[#{SiteChecks.file_label(file["kind"])}](#{file["url"]})" <> note(file["title"])
      end),
      group("Code and packages from #{domain}", from_site, &code_line/1),
      group("May be related (named like #{domain}, not linked to it)", related, &code_line/1),
      Enum.map_join(findings["unsearched"], "\n", fn source ->
        "_#{SiteChecks.source_label(source)} could not be searched just now._"
      end)
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n\n")
  end

  defp group(_title, [], _line), do: nil

  defp group(title, entries, line),
    do: "### #{title}\n\n" <> Enum.map_join(entries, "\n", &("- " <> line.(&1)))

  defp code_line(entry) do
    "[#{line(entry["name"])}](#{entry["url"]}) · #{SiteChecks.source_label(entry["source"])}" <>
      note(entry["description"])
  end

  defp note(text) when text in [nil, ""], do: ""
  defp note(text), do: " — " <> line(text)
end
