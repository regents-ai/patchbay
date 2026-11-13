defmodule PatchbayWeb.ForumAPI.AdvisoryFeedTest do
  @moduledoc """
  An advisory copied from cve.now is news: however new, it never reads as
  waiting for an answer, on the API, the hosted tools, the endpoint the page's
  search_threads tool reads or the home page. A new question written on
  Patchbay does, and a caller can ask for either kind alone.
  """

  use PatchbayWeb.ConnCase, async: true
  use ExUnitProperties

  alias Patchbay.Forum
  alias Patchbay.Forum.BoardActivity
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Discussions
  alias PatchbayWeb.OpenAPIShape

  @spec_file "priv/public/openapi.json"

  defp advisory!(board, n) do
    Forum.mirror_cve_now!(%{
      site_id: board.id,
      title: "CVE-2026-#{100_000 + n}: Example gateway flaw #{n}",
      body_markdown: "An attacker can run code.",
      topic_tags: ["cve-2026-#{100_000 + n}"],
      browser_session_id: Patchbay.Config.agent_session_id(),
      cve_now_id: "CVE-2026-#{100_000 + n}",
      cve_now_modified_at: DateTime.utc_now()
    })
  end

  # Asked with nobody signed in, from one browser session: who may post is
  # not under test here.
  defp ask!(site, title, session \\ Ash.UUID.generate()) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: session,
        title: title,
        thread_kind: :help_needed,
        body_markdown: "What I tried: " <> title
      },
      authorize?: false
    )
  end

  # Replied with nobody signed in: who may reply is not under test here.
  defp reply!(post, session, words) do
    Forum.add_reply!(
      %{report_id: post.id, browser_session_id: session, verdict: :unknown, note: words},
      authorize?: false
    )
  end

  defp search(conn, params), do: json_response(get(conn, "/forum/search", params), 200)
  defp ids(body), do: Enum.map(body["results"], & &1["id"])
  defp id_set(body), do: MapSet.new(ids(body))

  # Every post a search lists, page after page, as an agent follows it.
  defp every_page(conn, params, offset) do
    body = search(conn, Map.put(params, "offset", Integer.to_string(offset)))

    case body["pagination"] do
      %{"has_more" => false, "next_offset" => nil} -> ids(body)
      %{"has_more" => true, "next_offset" => next} -> ids(body) ++ every_page(conn, params, next)
    end
  end

  defp mcp(conn, path, name, arguments) do
    %{"result" => result} =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        path,
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{"name" => name, "arguments" => arguments}
        })
      )
      |> json_response(200)

    refute result["isError"], inspect(result)
    result["structuredContent"]
  end

  defp states(entry), do: Map.take(entry, ~w(source_kind discussion_state needs_answer))

  @news %{"source_kind" => "advisory", "discussion_state" => "news", "needs_answer" => false}
  @waiting %{
    "source_kind" => "original",
    "discussion_state" => "awaiting_help",
    "needs_answer" => true
  }

  describe "a fresh advisory and a fresh question" do
    setup do
      board = Forum.register_site!("cve.now")
      %{advisory: advisory!(board, 1), question: ask!(board, "Why does the feed skip a record?")}
    end

    test "over HTTP, every way of searching and reading them says which is waiting", %{
      conn: conn,
      advisory: advisory,
      question: question
    } do
      spec = @spec_file |> File.read!() |> Jason.decode!()

      # Each way an agent searches: a board, the feed, words, a tag, a filter.
      for {params, expected} <- [
            {%{"origin" => "cve.now"}, [advisory, question]},
            {%{"origin" => "cve.now", "sort" => "recent"}, [advisory, question]},
            {%{"q" => "record"}, [question]},
            {%{"q" => "gateway flaw"}, [advisory]},
            {%{"tag" => "cve-2026-100001"}, [advisory]},
            {%{"source_kind" => "advisory"}, [advisory]},
            {%{"source_kind" => "original"}, [question]},
            {%{"source_kind" => "original", "q" => "record"}, [question]},
            {%{"source_kind" => "advisory", "origin" => "cve.now"}, [advisory]}
          ] do
        results = search(conn, params)["results"]
        assert MapSet.new(results, & &1["id"]) == MapSet.new(expected, & &1.id), inspect(params)

        for entry <- results do
          assert states(entry) == if(entry["id"] == advisory.id, do: @news, else: @waiting)
        end
      end

      body = search(conn, %{"origin" => "cve.now"})
      assert id_set(body) == MapSet.new([advisory.id, question.id])
      OpenAPIShape.assert_shape(spec, OpenAPIShape.response_schema(spec, "/forum/search"), body)

      for {post, expected} <- [{advisory, @news}, {question, @waiting}] do
        thread = json_response(get(conn, "/forum/threads/#{post.id}"), 200)
        assert states(thread["report"]) == expected

        OpenAPIShape.assert_shape(
          spec,
          OpenAPIShape.response_schema(spec, "/forum/threads/{id}"),
          thread
        )
      end
    end

    test "at /mcp and the ChatGPT address, search_threads and get_thread say the same", %{
      conn: conn,
      advisory: advisory,
      question: question
    } do
      for path <- ["/mcp", "/chatgpt/mcp"] do
        conn = if path == "/chatgpt/mcp", do: on_open(conn), else: conn

        help = mcp(conn, path, "search_threads", %{"source_kind" => "original"})
        assert ids(help) == [question.id]
        assert states(hd(help["results"])) == @waiting

        news = mcp(conn, path, "search_threads", %{"source_kind" => "advisory"})
        assert ids(news) == [advisory.id]
        assert states(hd(news["results"])) == @news

        for {post, expected} <- [{advisory, @news}, {question, @waiting}] do
          thread = mcp(conn, path, "get_thread", %{"thread_id" => post.id})
          assert states(thread["report"]) == expected
        end
      end
    end

    test "the home page lists the question and leaves the advisory to its own tab", %{
      conn: conn,
      advisory: advisory,
      question: question
    } do
      listed = fn path ->
        conn
        |> get(path)
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("li[id^='feed-']")
        |> LazyHTML.attribute("id")
        |> MapSet.new()
      end

      shown = fn post -> "feed-#{post.id}" end

      for path <- ["/", "/?sort=popular", "/?scope=unanswered"] do
        assert shown.(question) in listed.(path), path
        refute shown.(advisory) in listed.(path), path
      end

      assert listed.("/?source_kind=advisory") == MapSet.new([shown.(advisory)])

      current =
        conn
        |> get("/?source_kind=advisory")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query(".pb-feed-tabs a[aria-current='page']")
        |> LazyHTML.attribute("href")

      assert current == ["/?scope=newest&sort=recent&source_kind=advisory"]
    end

    test "the counts of open questions leave the advisory out", %{question: question} do
      board = Forum.get_site_by_origin!("cve.now")

      for {params, count} <- [
            {%{}, 1},
            {%{"scope" => "unanswered"}, 1},
            {%{"source_kind" => "advisory"}, 1},
            {%{"source_kind" => "original"}, 1}
          ] do
        {:ok, filters} = Discussions.filters(params)
        assert Discussions.count(filters) == {:ok, count}, inspect(params)
      end

      assert %{count: 1, threads: [%{id: id}]} = Board.site_standing(board).open
      assert id == question.id
    end

    test "the board's post figure counts the question, and a reply to the advisory still counts",
         %{advisory: advisory} do
      reply!(advisory, Ash.UUID.generate(), "Patched on our side with the vendor's fix.")

      assert {:ok, %{posts: 1, replies: 1}} = BoardActivity.read()
    end
  end

  # The first hourly use: twenty advisories copied at once land on top of two
  # questions people are waiting on.
  describe "twenty advisories on top of two questions" do
    setup do
      board = Forum.register_site!("cve.now")
      shop = Forum.register_site!("shop.example")
      questions = [ask!(shop, "Why is the total wrong?"), ask!(board, "Why is a record missing?")]
      %{questions: questions, advisories: for(n <- 1..20, do: advisory!(board, n))}
    end

    test "help requests only and advisories only each keep their own pages", %{
      conn: conn,
      questions: questions,
      advisories: advisories
    } do
      asked = MapSet.new(questions, & &1.id)
      copied = MapSet.new(advisories, & &1.id)

      # Help requests only, and the feed with no filter: both questions on
      # the first page, every one waiting for an answer.
      for params <- [
            %{"source_kind" => "original"},
            %{"source_kind" => "original", "sort" => "popular"},
            %{"sort" => "recent"}
          ] do
        body = search(conn, params)
        assert id_set(body) == asked, inspect(params)
        assert Enum.all?(body["results"], &(states(&1) == @waiting))
        assert body["pagination"] == %{"has_more" => false, "next_offset" => nil}
      end

      # Advisories only, and the cve.now board with all 21 of its posts, each
      # read to the end through pagination.next_offset, every post once.
      on_board = List.last(questions).id

      for {params, expected} <- [
            {%{"source_kind" => "advisory"}, copied},
            {%{"source_kind" => "advisory", "sort" => "popular"}, copied},
            {%{"origin" => "cve.now"}, MapSet.put(copied, on_board)},
            {%{"origin" => "cve.now", "source_kind" => "original"}, MapSet.new([on_board])},
            {%{"origin" => "cve.now", "source_kind" => "advisory"}, copied}
          ] do
        read = every_page(conn, params, 0)
        assert read == Enum.uniq(read), inspect(params)
        assert MapSet.new(read) == expected, inspect(params)
      end
    end

    test "a source_kind that is neither kind is refused", %{conn: conn} do
      for kind <- ["news", "Advisory", "original,advisory"] do
        assert %{"error" => %{"code" => "invalid"}} =
                 json_response(get(conn, "/forum/search", %{"source_kind" => kind}), 422)
      end
    end
  end

  # Any mix of posts: advisories and questions, replied to by others or only
  # by their asker, some with an answer picked. Each run adds its posts to the
  # ones before it, so the property holds over every post on the board.
  property "no post copied from cve.now ever needs an answer; a question does until it is solved" do
    board = Forum.register_site!("cve.now")

    check all(
            mix <-
              list_of(
                fixed_map(%{
                  advisory?: boolean(),
                  by_others: integer(0..2),
                  by_asker: integer(0..1),
                  solved?: boolean()
                }),
                min_length: 1,
                max_length: 4
              ),
            max_runs: 25
          ) do
      {posts, expected} =
        mix
        |> Enum.map(fn shape ->
          {post, asker} =
            if shape.advisory? do
              n = System.unique_integer([:positive])
              {advisory!(board, n), Patchbay.Config.agent_session_id()}
            else
              asker = Ash.UUID.generate()
              {ask!(board, "Why is a record missing?", asker), asker}
            end

          others =
            for _n <- 1..shape.by_others//1, do: reply!(post, Ash.UUID.generate(), "Try this.")

          for _n <- 1..shape.by_asker//1, do: reply!(post, asker, "Still stuck.")

          solved? = shape.solved? and others != []
          if solved?, do: {:ok, _} = Forum.mark_solution(post, hd(others).id, asker, nil)

          {post, expected(shape.advisory?, solved?, others)}
        end)
        |> Enum.unzip()

      read = Ash.load!(posts, [:source_kind, :needs_answer, :discussion_state])
      assert Enum.map(read, &{&1.source_kind, &1.needs_answer, &1.discussion_state}) == expected
    end
  end

  defp expected(true = _advisory?, _solved?, _others), do: {:advisory, false, :news}
  defp expected(false, true = _solved?, _others), do: {:original, false, :solved}
  defp expected(false, false, []), do: {:original, true, :awaiting_help}
  defp expected(false, false, _others), do: {:original, true, :in_discussion}
end
