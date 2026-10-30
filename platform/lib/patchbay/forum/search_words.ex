defmodule Patchbay.Forum.SearchWords do
  @moduledoc """
  The threads a search's words find (`Patchbay.Forum.Report`'s `:search`),
  read from indexes rather than every post.

  A thread is found by its own words, its title spelled a little wrong or an
  exact tool name; by its site's address or name; by its own words and its
  site's together, each holding some of the words typed; by a published reply's
  words and fix; or by a published card. Each place's words (`search_vector`)
  are written exactly as the index built for them, and the words typed are read
  as quoted words (`Patchbay.Forum.SearchTerms`). PostgreSQL cannot use an
  index for each place when they are joined by "or", even within one table (a
  common word then reads every thread and rebuilds its words), so each is its
  own query, each reading its index, and the search keeps the threads any of
  them found.

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
         {:ok, ranked} <- first_by_rank(ash_query, term),
         {:ok, worked} <- worked() do
      first_unworked =
        ranked
        |> where([t], t.id in subquery(found) and t.id not in subquery(worked))
        |> exclude(:select)
        |> select([t], t.id)

      candidates =
        from(t in threads,
          where: t.id in subquery(found) and t.id in subquery(worked),
          select: t.id
        )
        |> union(^from(t in subquery(first_unworked), select: t.id))

      {:ok, where(query, [thread], thread.id in subquery(candidates))}
    end
  end

  def modify(_ash_query, query), do: {:ok, query}

  defp found(term) do
    [
      Ash.Query.filter(Report, fragment("? @@ ?", search_vector, search_terms(^term, :all))),
      Ash.Query.filter(Report, fragment("? @> ARRAY[?]::text[]", tool_names, ^term)),
      Ash.Query.filter(Report, fragment("? OPERATOR(public.<%) ?", ^term, title)),
      # Asked as "its site matches" rather than through the site joined in: a
      # joined site may be missing, and a missing site's words read as empty
      # rather than nothing, so PostgreSQL would read every thread to check.
      Ash.Query.filter(
        Report,
        exists(
          site,
          origin == ^term or fragment("? @@ ?", search_vector, search_terms(^term, :all))
        )
      ),
      # Some words in the thread and the rest in its site's address or name:
      # each holds one word at least, which both indexes answer, and together
      # they hold every word.
      Ash.Query.filter(
        Report,
        fragment("? @@ ?", search_vector, search_terms(^term, :any)) and
          fragment("? @@ ?", site.search_vector, search_terms(^term, :any)) and
          fragment(
            "(? || ?) @@ ?",
            search_vector,
            site.search_vector,
            search_terms(^term, :all)
          )
      ),
      Ash.Query.filter(
        Report,
        exists(
          replies,
          visibility == :published and
            fragment("? @@ ?", search_vector, search_terms(^term, :all))
        )
      ),
      Ash.Query.filter(
        Report,
        exists(
          solution_cards,
          fragment("? @@ ?", search_vector, search_terms(^term, :all))
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

  # The same threads in the order of those nobody says worked yet (rank, last
  # activity, id), as many as reach the end of the page asked for.
  defp first_by_rank(ash_query, term) do
    ash_query
    |> Ash.Query.unset([:sort, :load, :limit, :offset])
    |> Ash.Query.sort(search_rank: {%{term: term}, :desc}, last_activity_at: :desc, id: :desc)
    |> Ash.Query.limit(ash_query.offset + ash_query.limit)
    |> Ash.Query.data_layer_query(no_modify?: true)
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
