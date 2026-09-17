defmodule PatchbayWeb.Forum.Discussions do
  @moduledoc "Read-only discussion workbench over existing reports; no second thread store."

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias PatchbayWeb.Endpoint

  @salt "discussion-pages-v1"
  @scopes ~w(all unanswered priority following)
  @loads [
    :author,
    :reply_count,
    :bounty_open,
    :verified_paid_usdc_atomic,
    :post_kind,
    :site,
    :tool
  ]

  def filters(params) do
    %{
      q: text(params["q"], 200),
      site: text(params["site"], 255),
      scope: if(params["scope"] in @scopes, do: params["scope"], else: "all")
    }
  end

  @doc "The subscriptions a request's own principals hold — the durable follow list."
  def subscriptions(principals) do
    Patchbay.Forum.Subscription
    |> Ash.Query.filter(principal in ^principals)
    |> Ash.read!()
  end

  def page(filters, subscriptions, token) do
    context =
      {filters,
       if(filters.scope == "following",
         do: subscriptions |> Enum.map(&{&1.scope_kind, &1.scope_id}) |> Enum.sort(),
         else: []
       )}

    with {:ok, keyset} <- verify(token, context),
         {:ok, page} <-
           Forum.list_recent_reports(
             query: query(filters, subscriptions),
             load: @loads,
             page: if(keyset, do: [limit: 20, after: keyset], else: [limit: 20])
           ) do
      {:ok, page.results, continuation(page, context)}
    end
  end

  # Search the report text as well as its site/tool. Filtering happens before
  # keyset pagination, not against an arbitrary handful of tool versions.
  defp query(filters, following) do
    Report
    |> Ash.Query.filter(visibility == :published)
    |> search(filters.q)
    |> site(filters.site)
    |> scope(filters.scope, following)
  end

  defp search(query, ""), do: query

  defp search(query, term) do
    Ash.Query.filter(
      query,
      fragment(
        "(coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')) ILIKE ('%' || lower(?) || '%')",
        title,
        body_markdown,
        note,
        subject_tool_name,
        tool.name,
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

  defp scope(query, "unanswered", _following), do: Ash.Query.filter(query, reply_count == 0)

  # Recorded paid placement is not proof that an answer is correct. Do not
  # include pending payment intents or refunded reports in this scope.
  defp scope(query, "priority", _following) do
    Ash.Query.filter(query, verified_paid_usdc_atomic > 0)
  end

  # Following is the caller's own subscriptions: followed sites, tools and
  # threads all surface here.
  defp scope(query, "following", subscriptions) do
    sites = for %{scope_kind: :site, scope_id: id} <- subscriptions, do: id
    tools = for %{scope_kind: :tool, scope_id: id} <- subscriptions, do: id
    threads = for %{scope_kind: :thread, scope_id: id} <- subscriptions, do: id

    Ash.Query.filter(query, site_id in ^sites or tool_id in ^tools or id in ^threads)
  end

  defp scope(query, _scope, _following), do: query

  defp continuation(%{more?: true, results: results}, context) do
    Phoenix.Token.sign(Endpoint, @salt, {context, List.last(results).__metadata__.keyset})
  end

  defp continuation(_page, _context), do: nil

  defp verify(nil, _context), do: {:ok, nil}

  defp verify(token, context) when is_binary(token) and byte_size(token) <= 8192 do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: 86_400) do
      {:ok, {^context, keyset}} when is_binary(keyset) -> {:ok, keyset}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp verify(_token, _context), do: {:error, :invalid_cursor}

  defp text(value, limit) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, limit)

  defp text(_value, _limit), do: ""
end
