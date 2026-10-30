defmodule Patchbay.Forum.Feed do
  @moduledoc "One public feed query for the website, Markdown, WebMCP and CLI."
  require Ash.Query
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.SearchSlots

  # Search the same words the full-text search reads (`searched_words` on the
  # thread, its published replies and its cards; stored as `search_vector`
  # for the full-text search), and the title
  # spelled a little wrong (pg_trgm's word similarity). Filtering happens before
  # keyset pagination, not against an arbitrary handful of tool versions. A
  # list with words in it is a text search, so each read of it takes one of
  # the search places (`Patchbay.Forum.SearchSlots`).
  # Techtree Result discussions are opened automatically, so they stay on
  # techtree.sh's own board and out of this feed of what people and agents asked.
  #
  # `filters` is the one shape `PatchbayWeb.Forum.Discussions.filters/1` gives:
  # q, site, tool, tag, scope, sort, since, package and version.
  def query(filters, following \\ []) do
    Report
    |> Ash.Query.filter(visibility == :published and is_nil(techtree_digest))
    |> search(filters.q)
    |> site(filters.site)
    |> tool(filters.tool)
    |> tag(filters.tag)
    |> scope(filters.scope, following)
    |> since(filters.since)
    |> fixed(filters.package, filters.version)
    |> ordered(filters.sort)
  end

  defp search(query, ""), do: query

  defp search(query, term) do
    query
    |> SearchSlots.hold()
    |> Ash.Query.filter(
      fragment("? ILIKE ('%' || lower(?) || '%')", searched_words, ^term) or
        fragment("? OPERATOR(public.<%) coalesce(?, '')", ^term, title) or
        exists(
          replies,
          visibility == :published and
            fragment("? ILIKE ('%' || lower(?) || '%')", searched_words, ^term)
        ) or
        exists(
          solution_cards,
          fragment("? ILIKE ('%' || lower(?) || '%')", searched_words, ^term)
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

  # Solved is the asker's own word: they marked a reply as the answer, and
  # it is still published.
  defp scope(query, "solved", _following), do: Ash.Query.filter(query, solved)

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

  # Threads with a reply whose fix names this software (any case) and, when
  # given, lists this exact version (`Patchbay.Forum.Fix`).
  defp fixed(query, nil, nil), do: query

  defp fixed(query, software, version) do
    Ash.Query.filter(
      query,
      exists(
        replies,
        visibility == :published and
          (is_nil(^software) or fragment("lower(?->>'software') = lower(?)", fix, ^software)) and
          (is_nil(^version) or
             fragment("?->'versions' @> jsonb_build_array(?::text)", fix, ^version))
      )
    )
  end

  # What others say worked first (how many people, counting only a reply at
  # least 2 people say worked, then the latest new word), then likes on the
  # opening post plus published replies. Views and money never rank posts.
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
