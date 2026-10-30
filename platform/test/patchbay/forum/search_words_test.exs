defmodule Patchbay.Forum.SearchWordsTest do
  @moduledoc """
  A word search reads an index for every place a thread's words can be
  (`Patchbay.Forum.SearchWords`), and the questions list newest first reads
  its own (`Patchbay.Forum.Feed`), never every row of a table. A list with
  words in it finds what the word search finds, each word at the start of a
  word.
  """

  use Patchbay.DataCase, async: true

  alias Patchbay.Forum
  alias Patchbay.Forum.{Feed, FeedCount}

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

    Forum.search_threads!("nonce", page: [limit: 10])
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

    for search <- [&listed/1, &searched/1] do
      assert search.("example.com webhookfail#{n}") == [thread.id]
      assert search.("webhookfail#{n} example.com") == [thread.id]
      assert search.("example.com webhookfail#{n} nowhere#{n}") == []
    end
  end

  describe "a list with words in it" do
    setup do
      %{site: Forum.register_site!("search-words-#{System.unique_integer([:positive])}.example")}
    end

    test "finds a word by its beginning, never by its middle", %{site: site} do
      thread = ask!(site, "The cart never changed", "The quaggapayment failed at checkout.")

      for search <- [&listed/1, &searched/1] do
        assert search.("quaggapay") == [thread.id]
        assert search.("quaggapayments") == [thread.id]
        assert search.("payment") == []
      end
    end

    test "finds only the last word typed by its beginning, and never a number", %{site: site} do
      thread =
        ask!(
          site,
          "Card declined",
          "The payment failed at checkout on tool_31, error 5004, build 1234, v1.2.30, 1.0.220."
        )

      for search <- [&listed/1, &searched/1] do
        assert search.("pay") == [thread.id]
        assert search.("checkout pay") == [thread.id]
        assert search.("pay checkout") == []
        assert search.("pa") == []
        assert search.("1") == []
        assert search.("500") == []
        assert search.("tool_3") == []
        assert search.("tool_31") == [thread.id]
        assert search.("error 5004") == [thread.id]
        assert search.("1.0.22") == []
        assert search.("v1.2.3") == []
        assert search.("1.0.220") == [thread.id]
      end
    end

    test "finds a title spelled a little wrong only when one word is typed", %{site: site} do
      thread = ask!(site, "Card declined at checkout", "Nothing more to say.")

      for search <- [&listed/1, &searched/1] do
        assert search.("checkot") == [thread.id]
        assert search.("checkout x") == []
        assert search.("checkout-x") == []
        assert search.("checkout zzzzqq") == []
      end
    end

    test "holds the same threads as the word search", %{site: site} do
      ask!(site, "Wallet will not connect", "The approve step hangs on a nonce too low error.")
      ask!(site, "Checkout fails", "Payments stop at the approve step.")
      ask!(site, "Rainbow sign in", "eth_sendRawTransaction answers nothing.")
      ask!(site, "Nothing in common", "A plain question.")

      for words <- ["approve", "pay", "nonce too", "eth_send", site.origin, "connect", "zzz"] do
        assert Enum.sort(listed(words)) == Enum.sort(searched(words)), words
      end

      assert length(listed("approve")) == 2
    end

    test "counts the threads it lists", %{site: site} do
      n = System.unique_integer([:positive])
      ask!(site, "Counted once", "countword#{n} in the first.")
      ask!(site, "Counted twice", "countword#{n} in the second.")
      ask!(site, "Not counted", "Nothing to find here.")

      {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{"q" => "countword#{n}"})

      assert FeedCount.count(filters, []) == {:ok, 2}
      assert length(listed("countword#{n}")) == 2
    end

    test "reads the search indexes" do
      {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{"q" => "nonce"})

      {:ok, query} =
        filters
        |> Feed.query()
        |> Ash.Query.for_read(:feed)
        |> Ash.Query.limit(20)
        |> Ash.Query.data_layer_query()

      {sql, params} = Repo.to_sql(:all, query)

      for scan <- ~w(seqscan indexscan indexonlyscan),
          do: Repo.query!("SET LOCAL enable_#{scan} = off")

      plan = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)

      for index <- @indexes, do: assert(plan =~ index, "#{index} not read:\n#{plan}")
    end
  end

  test "the questions list, newest first, reads its own index" do
    {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{})

    {:ok, query} =
      filters
      |> Feed.query()
      |> Ash.Query.for_read(:feed)
      |> Ash.Query.limit(20)
      |> Ash.Query.data_layer_query()

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

  # The threads the questions list with these words holds, and those the word
  # search finds.
  defp listed(words) do
    {:ok, filters} = PatchbayWeb.Forum.Discussions.filters(%{"q" => words})

    Forum.list_feed_reports!(query: Feed.query(filters), page: [limit: 50]).results
    |> Enum.map(& &1.id)
  end

  defp searched(words),
    do: Forum.search_threads!(words, page: [limit: 50]).results |> Enum.map(& &1.id)
end
