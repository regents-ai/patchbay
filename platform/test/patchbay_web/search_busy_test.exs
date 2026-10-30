defmodule PatchbayWeb.SearchBusyTest do
  @moduledoc """
  A word search takes one of two places and has two seconds to read
  (`Patchbay.Forum.SearchSlots`). A search with no place free, or whose read
  runs out of time, asks to be sent again shortly at every door: the forum
  API answers 503 with Retry-After, the MCP tool answers `unavailable`, and
  the search window says so. It never answers 500 or an empty list.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Forum
  alias Patchbay.Forum.SearchSlots
  alias Patchbay.Forum.SearchUnavailable

  describe "with both places taken" do
    setup do
      hold_both_places()
      :ok
    end

    test "the forum API answers 503 with Retry-After", %{conn: conn} do
      conn = get(conn, "/forum/search?q=reservation")

      assert %{"error" => %{"code" => "unavailable", "message" => message}} =
               json_response(conn, 503)

      assert message == SearchUnavailable.words()
      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "the MCP tool answers unavailable", %{conn: conn} do
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

      assert %{"error" => %{"code" => "unavailable", "message" => message}} = Jason.decode!(text)
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

  test "a read that runs past two seconds is stopped and answers unavailable" do
    Forum.register_site!("slow.example")
    block_reports()

    {microseconds, answer} = :timer.tc(fn -> Forum.search_threads("reservation") end)

    assert {:error, error} = answer
    assert SearchUnavailable.in?(error)
    assert microseconds in 2_000_000..4_000_000
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

  # Another connection locks the reports table until the test ends, so the
  # search's read waits on the lock past its two seconds.
  defp block_reports do
    test = self()

    blocker =
      spawn_link(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Patchbay.Repo)
        Patchbay.Repo.query!("LOCK TABLE forum_reports IN ACCESS EXCLUSIVE MODE")
        send(test, :locked)
        receive do: (:release -> :ok)
      end)

    assert_receive :locked
    on_exit(fn -> send(blocker, :release) end)
  end

  defp visitor, do: "visitor-" <> Ash.UUID.generate()
end
