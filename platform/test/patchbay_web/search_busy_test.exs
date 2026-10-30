defmodule PatchbayWeb.SearchBusyTest do
  @moduledoc """
  Every text search takes one of two places and has two seconds to read
  (`Patchbay.Forum.SearchSlots`): the word search, the question list with words
  in it and its count, and the site and tool matches. A search with no place
  free, or whose read runs out of time, asks to be sent again shortly at every
  door: the forum API answers 503 `busy` with Retry-After, the MCP tool answers
  `busy` with the seconds to wait, the home page says so in place of the list, and the search
  window says so. It never answers 500 or an empty list. Any other error is a
  fault and is never answered as busy.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.FeedCount
  alias Patchbay.Forum.SearchSlots
  alias Patchbay.Forum.SearchUnavailable
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Discussions

  describe "with both places taken" do
    setup do
      hold_both_places()
      :ok
    end

    test "the forum API answers 503 with Retry-After", %{conn: conn} do
      conn = get(conn, "/forum/search?q=reservation")

      assert %{"error" => %{"code" => "busy", "message" => message, "retry_after_seconds" => 2}} =
               json_response(conn, 503)

      assert message == SearchUnavailable.words()
      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "the forum API's newest-first list with words answers 503 with Retry-After", %{
      conn: conn
    } do
      conn = get(conn, "/forum/search?q=reservation&sort=recent")

      assert %{"error" => %{"code" => "busy"}} = json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "the home page with words says search is busy in place of the list", %{conn: conn} do
      conn = get(conn, "/?q=reservation")

      html = html_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["2"]
      assert html =~ "Search is busy right now."
      refute html =~ "could not be loaded"
    end

    test "the home page without words takes no place", %{conn: conn} do
      assert conn |> get("/") |> html_response(200)
    end

    test "the site and tool matches take a place" do
      assert {:error, error} = Board.matches("reservation")
      assert SearchUnavailable.in?(error)
    end

    test "counting a list with words takes a place; counting one without does not" do
      {:ok, words} = Discussions.filters(%{"q" => "reservation"})
      assert {:error, error} = FeedCount.count(words, [])
      assert SearchUnavailable.in?(error)

      {:ok, plain} = Discussions.filters(%{})
      assert {:ok, _count} = FeedCount.count(plain, [])
    end

    test "the MCP tool answers busy", %{conn: conn} do
      call = %{"name" => "search_threads", "arguments" => %{"q" => "reservation"}}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/mcp",
          Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: call})
        )

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert %{"error" => %{"code" => "busy", "message" => message, "retry_after_seconds" => 2}} =
               Jason.decode!(text)

      assert message == SearchUnavailable.words()
    end

    test "the search window says search is unavailable", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, PatchbayWeb.SearchLive, session: %{"visitor" => visitor()})

      render_hook(view, "open", %{"recent" => []})
      render_async(view, 2_000)

      view |> form("#shell-search-form", %{"q" => "reservation"}) |> render_change()

      assert render_async(view, 2_000) =~ "Search is unavailable right now."
    end
  end

  test "a read that runs past two seconds is stopped and answers busy" do
    Forum.register_site!("slow.example")
    lock_table("forum_reports")

    {microseconds, answer} = :timer.tc(fn -> Forum.search_threads("reservation") end)

    assert {:error, error} = answer
    assert cause(error) == :timeout
    assert microseconds in 2_000_000..4_000_000
  end

  test "busy site and tool matches say so under a list that was read", %{conn: conn} do
    lock_table("forum_tools")

    html = conn |> get("/?q=reservation") |> html_response(200)

    assert html =~ "Search is busy right now."
    assert html =~ "were not searched"
    refute html =~ "could not be loaded"
  end

  test "the home page reads a list with words once, and does not count it", %{conn: conn} do
    html = conn |> get("/?q=reservation") |> html_response(200) |> LazyHTML.from_document()

    assert html |> LazyHTML.query(".pb-feed-status") |> Enum.empty?()
  end

  test "a database fault is not answered as busy" do
    Patchbay.Repo.query!("ALTER TABLE forum_reports RENAME COLUMN visibility TO hidden_away")

    assert {:error, error} = Forum.search_threads("reservation")
    refute SearchUnavailable.in?(error)
  end

  # Two searches elsewhere, each holding its place until the test ends.
  defp hold_both_places do
    test = self()

    holders = for _place <- 1..2, do: spawn_link(fn -> hold_place(test) end)

    for _holder <- holders, do: assert_receive(:holding)
    on_exit(fn -> Enum.each(holders, &send(&1, :release)) end)
  end

  defp hold_place(test) do
    NimblePool.checkout!(SearchSlots, :search, fn _from, slot ->
      send(test, :holding)
      receive do: (:release -> {:ok, slot})
    end)
  end

  # Another connection locks `table` until the test ends, so a search reading
  # it waits on the lock past its two seconds.
  defp lock_table(table) do
    test = self()

    blocker =
      spawn_link(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Patchbay.Repo)
        Patchbay.Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
        send(test, :locked)
        receive do: (:release -> :ok)
      end)

    assert_receive :locked
    on_exit(fn -> send(blocker, :release) end)
  end

  defp visitor, do: "visitor-" <> Ash.UUID.generate()

  defp cause(%SearchUnavailable{cause: cause}), do: cause
  defp cause(%{errors: errors}), do: Enum.find_value(errors, &cause/1)
  defp cause(_error), do: nil
end
