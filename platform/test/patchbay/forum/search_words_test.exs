defmodule Patchbay.Forum.SearchWordsTest do
  @moduledoc """
  A word search reads an index for every place a thread's words can be
  (`Patchbay.Forum.SearchWords`), and the questions list newest first reads
  its own (`Patchbay.Forum.Feed`), never every row of a table.
  """

  use Patchbay.DataCase, async: true

  alias Patchbay.Forum
  alias Patchbay.Forum.Feed

  @indexes ~w(
    forum_reports_search_words_index
    forum_reports_title_trgm_index
    forum_reports_tool_names_index
    forum_sites_search_words_index
    forum_replies_search_words_index
    forum_solution_cards_search_words_index
  )

  test "each place a search looks reads its own index" do
    test = self()
    handler = "search-words-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:patchbay, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.query =~ "unnest(to_tsvector" and meta.query =~ "<%",
          do: send(test, {:searched, meta.query, meta.params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Forum.search_threads!("nonce too low", page: [limit: 10])
    assert_received {:searched, sql, params}

    # With every way to read a table but a bitmap of index matches turned off,
    # PostgreSQL plans with an index wherever one answers a condition, however
    # few rows the tables hold; a part no index can answer names none.
    for scan <- ~w(seqscan indexscan indexonlyscan),
        do: Repo.query!("SET LOCAL enable_#{scan} = off")

    plan = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)

    for index <- @indexes, do: assert(plan =~ index, "#{index} not read:\n#{plan}")
  end

  test "finds a thread by its own words and its site's together" do
    n = System.unique_integer([:positive])
    site = Forum.register_site!("example.com")
    thread = ask!(site, "Hooks stopped", "Every call ends in webhookfail#{n}.")

    assert searched("example.com webhookfail#{n}") == [thread.id]
    assert searched("webhookfail#{n} example.com") == [thread.id]
    assert searched("example.com webhookfail#{n} nowhere#{n}") == []
  end

  test "the questions list, newest first, reads its own index" do
    {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{})
    {:ok, query} = filters |> Feed.query() |> Ash.Query.limit(20) |> Ash.Query.data_layer_query()
    {sql, params} = Repo.to_sql(:all, query)

    Repo.query!("SET LOCAL enable_seqscan = off")
    plan = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)

    assert plan =~ "forum_reports_feed_index", plan
    refute plan =~ "Sort", plan
  end

  defp ask!(site, title, body) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: body
      },
      # Posts the test's own thread; asking is not what this test checks.
      authorize?: false
    )
  end

  defp searched(words),
    do: Forum.search_threads!(words, page: [limit: 50]).results |> Enum.map(& &1.id)
end
