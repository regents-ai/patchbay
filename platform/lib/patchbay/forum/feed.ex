defmodule Patchbay.Forum.Feed do
  @moduledoc "One public feed query for the website, Markdown, WebMCP and CLI."
  require Ash.Query
  alias Patchbay.Forum.Report

  # Search the report text as well as its site/tool. Filtering happens before
  # keyset pagination, not against an arbitrary handful of tool versions.
  # Techtree Result discussions are opened automatically, so they stay on
  # techtree.sh's own board and out of this feed of what people and agents asked.
  def query(filters, following \\ []) do
    Report
    |> Ash.Query.filter(visibility == :published and is_nil(techtree_digest))
    |> search(filters.q)
    |> site(filters.site)
    |> tool(filters.tool)
    |> tag(filters.tag)
    |> scope(filters.scope, following)
    |> since(Map.get(filters, :since))
    |> ordered(Map.get(filters, :sort, "recent"))
  end

  defp search(query, ""), do: query

  defp search(query, term) do
    Ash.Query.filter(
      query,
      fragment(
        "(coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || array_to_string(?, ' ') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')) ILIKE ('%' || lower(?) || '%')",
        title,
        body_markdown,
        note,
        tool_names,
        site.origin,
        site.display_name,
        ^term
      ) or
        exists(
          replies,
          visibility == :published and
            fragment(
              "coalesce(?, '') || ' ' || coalesce(?, '') ILIKE ('%' || lower(?) || '%')",
              body_markdown,
              note,
              ^term
            )
        ) or
        exists(
          solution_cards,
          status == :published and
            fragment(
              "coalesce(?, '') || ' ' || coalesce(?, '') ILIKE ('%' || lower(?) || '%')",
              problem_summary,
              proposed_steps,
              ^term
            )
        )
    )
  end

  defp site(query, ""), do: query
  defp site(query, ref), do: Ash.Query.filter(query, site.origin == ^ref)

  defp tool(query, ""), do: query
  defp tool(query, name), do: Ash.Query.filter(query, ^name in tool_names)

  defp tag(query, ""), do: query
  defp tag(query, name), do: Ash.Query.filter(query, ^name in topic_tags)

  # Unanswered waits for anyone but the asker: their own follow-ups are not help.
  defp scope(query, "unanswered", _following),
    do: Ash.Query.filter(query, discussion_state == :awaiting_help)

  # Solved is the asker's own word: they marked a reply as the answer.
  defp scope(query, "solved", _following),
    do: Ash.Query.filter(query, not is_nil(solution_reply_id))

  # Following is the caller's own subscriptions: followed sites, tools and
  # threads all surface here.
  defp scope(query, "following", subscriptions) do
    sites = for %{scope_kind: :site, scope_id: id} <- subscriptions, do: id
    tools = for %{scope_kind: :tool, scope_id: id} <- subscriptions, do: id
    threads = for %{scope_kind: :thread, scope_id: id} <- subscriptions, do: id

    Ash.Query.filter(query, site_id in ^sites or tool_id in ^tools or id in ^threads)
  end

  defp scope(query, _scope, _following), do: query

  defp since(query, nil), do: query
  defp since(query, cutoff), do: Ash.Query.filter(query, last_activity_at >= ^cutoff)

  # What others say worked first (how many, then the latest who said so), then
  # likes on the opening post plus published replies. Views and money never
  # rank posts.
  defp ordered(query, "popular"),
    do:
      Ash.Query.sort(query,
        worked_count: :desc,
        last_worked_at: :desc_nils_last,
        feed_engagement: :desc,
        inserted_at: :desc,
        id: :desc
      )

  defp ordered(query, _), do: Ash.Query.sort(query, inserted_at: :desc, id: :desc)
end
