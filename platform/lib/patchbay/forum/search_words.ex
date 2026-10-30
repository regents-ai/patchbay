defmodule Patchbay.Forum.SearchWords do
  @moduledoc """
  The threads a search's words find (`Patchbay.Forum.Report`'s `:search`),
  read from indexes rather than every post.

  A thread is found by its own stored words, its title spelled a little wrong or
  an exact tool name; by its site's address or name, matched on the site's own
  stored words; by a published reply's words and fix; or by a published card.
  PostgreSQL cannot use an index for each of those when they are joined by "or"
  across four tables, so each is its own query, each reading its index, and the
  search keeps the threads any of them found.

  A common word finds most threads, and the search's order counts what others
  say worked on each one, which is slow to count for thousands. Only a thread
  with a reply at least `Report.worked_by_at_least/0` people say worked can have
  such a count; every other thread counts none, so among those the order is
  rank, then last activity, then id, read from the thread's own columns. The
  search therefore counts only the threads that can have one, plus the first
  page's worth of the rest in that order: the same page, in the same order, as
  counting every thread found.
  """

  require Ash.Query

  import Ecto.Query,
    only: [
      exclude: 2,
      from: 2,
      group_by: 3,
      having: 3,
      select: 3,
      subquery: 1,
      union: 2,
      where: 3
    ]

  alias Patchbay.Forum.{AnswerUse, Reply, Report}

  @doc "Narrows the search's own query to the threads its words find; no words, no change."
  def modify(%Ash.Query{arguments: %{term: term}} = ash_query, query) when is_binary(term) do
    with {:ok, found} <- found(term),
         {:ok, threads} <- threads(ash_query),
         {:ok, worked} <- worked() do
      found_threads = where(threads, [t], t.id in subquery(found))

      first_unworked =
        from(t in found_threads,
          where: t.id not in subquery(worked),
          order_by: [
            desc: fragment("ts_rank(?, plainto_tsquery('english', ?))", t.search_vector, ^term),
            desc: t.last_activity_at,
            desc: t.id
          ],
          limit: ^(ash_query.offset + ash_query.limit),
          select: t.id
        )

      candidates =
        from(t in found_threads, where: t.id in subquery(worked), select: t.id)
        |> union(^from(t in subquery(first_unworked), select: t.id))

      {:ok, where(query, [thread], thread.id in subquery(candidates))}
    end
  end

  def modify(_ash_query, query), do: {:ok, query}

  defp found(term) do
    [
      Ash.Query.filter(
        Report,
        fragment("? @@ plainto_tsquery('english', ?)", search_vector, ^term) or
          fragment("? @> ARRAY[?]::text[]", tool_names, ^term) or
          fragment("? OPERATOR(public.<%) ?", ^term, title)
      ),
      Ash.Query.filter(
        Report,
        site.origin == ^term or
          fragment("? @@ plainto_tsquery('english', ?)", site.search_vector, ^term)
      ),
      Ash.Query.filter(
        Report,
        exists(
          replies,
          visibility == :published and
            fragment("? @@ plainto_tsquery('english', ?)", search_vector, ^term)
        )
      ),
      Ash.Query.filter(
        Report,
        exists(
          solution_cards,
          fragment("? @@ plainto_tsquery('english', ?)", search_vector, ^term)
        )
      )
    ]
    |> Enum.reduce_while({:ok, nil}, fn ash_query, {:ok, found} ->
      case ids(ash_query, :id) do
        {:ok, ids} -> {:cont, {:ok, either(found, ids)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp either(nil, ids), do: ids
  defp either(found, ids), do: union(found, ^ids)

  # The threads the search may show at all: its own filters and those of who is
  # asking, without its order, page or counts.
  defp threads(ash_query) do
    ash_query
    |> Ash.Query.unset([:sort, :load, :limit, :offset])
    |> Ash.Query.data_layer_query(no_modify?: true)
    |> case do
      {:ok, query} -> {:ok, exclude(query, :select)}
      {:error, error} -> {:error, error}
    end
  end

  # Every thread with a published reply that enough people may say worked:
  # each such reply has at least that many "worked" words, from anyone, so
  # this holds every thread `:worked_count` or `:last_worked_at` can count.
  defp worked do
    with {:ok, replies} <- ids(Ash.Query.filter(AnswerUse, outcome == :worked), :reply_id),
         {:ok, threads} <- ids(Ash.Query.filter(Reply, visibility == :published), :report_id) do
      worked_replies =
        replies
        |> group_by([use], use.reply_id)
        |> having([_use], count() >= ^Report.worked_by_at_least())

      {:ok, where(threads, [reply], reply.id in subquery(worked_replies))}
    end
  end

  defp ids(ash_query, field) do
    case Ash.Query.data_layer_query(ash_query) do
      {:ok, query} -> {:ok, query |> exclude(:select) |> select([row], field(row, ^field))}
      {:error, error} -> {:error, error}
    end
  end
end
