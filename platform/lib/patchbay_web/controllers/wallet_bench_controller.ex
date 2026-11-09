defmodule PatchbayWeb.WalletBenchController do
  @moduledoc """
  The Agent Wallet Bench board, `/wallet-bench`, one test at a time
  (`?test=wallet`; the first test when none is named), how the bench works,
  `/wallet-bench/how-it-works`, and one pair's runs,
  `/wallet-bench/<agent>/<wallet>`. All three show the bench as it was read
  within the last minute, shared with every visitor
  (`Patchbay.WalletBench.Board`), so a finished run shows within a minute and
  a visit reads nothing from Techtree's views. Until the bench has been read
  once since the site started, each answers 503 and says to try again in a
  minute; while four filtered boards are being built, a fifth answers 503
  busy.
  """

  use PatchbayWeb, :controller

  alias Patchbay.WalletBench
  alias Patchbay.WalletBench.Board
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.WalletBenchHTML
  alias PatchbayWeb.WalletBenchJSON

  def index(conn, params) do
    case WalletBench.board_page(params, get_format(conn) == "md") do
      {:ok, assigns} ->
        conn
        |> merge_assigns(PatchbayWeb.PublicDocuments.page("/wallet-bench"))
        |> render(:index, assigns ++ [page_data: [WalletBenchHTML.dataset(assigns[:matrix])]])

      :not_found ->
        raise NotFoundError

      why when why in [:unread, :busy] ->
        unavailable(conn, why)
    end
  end

  # The bench has not been read since the site started, or as many filtered
  # boards as may be built at once are being built: a 503 in the format asked
  # for, with no crash to log on every visit.
  defp unavailable(conn, why) do
    %{error: %{message: message, hint: hint}} = body = refusal(why)

    conn =
      conn
      |> put_status(:service_unavailable)
      |> put_resp_header("retry-after", retry_after(why))

    case get_format(conn) do
      "json" ->
        json(conn, body)

      _page ->
        conn
        |> merge_assigns(PatchbayWeb.PublicDocuments.page("/wallet-bench"))
        |> render(:unavailable, heading: heading(why), words: message <> " " <> hint)
    end
  end

  defp refusal(:unread),
    do:
      PatchbayWeb.ApiError.body(
        "not_ready",
        "Wallet Bench results are still being read.",
        "Try again in a minute."
      )

  defp refusal(:busy),
    do: PatchbayWeb.ApiError.body("busy", "Wallet Bench is busy.", "Try again in a few seconds.")

  defp retry_after(:unread), do: "60"
  defp retry_after(:busy), do: "5"

  defp heading(:unread), do: "Not ready"
  defp heading(:busy), do: "Busy"

  @doc """
  The board for one test, as a status and the body `GET /api/wallet-bench`
  answers with for the same query: the `read_wallet_bench` tool.
  """
  @spec read_wallet_bench(map()) :: {atom(), map()}
  def read_wallet_bench(params) do
    case WalletBench.board_page(params, false) do
      {:ok, assigns} -> {:ok, WalletBenchJSON.index(Map.new(assigns))}
      :not_found -> not_found()
      why when why in [:unread, :busy] -> {:service_unavailable, refusal(why)}
    end
  end

  @doc """
  One pair's runs, as a status and the body
  `GET /api/wallet-bench/{harness_id}/{wallet_id}` answers with for the same
  query: the `read_wallet_bench_pair` tool.
  """
  @spec read_wallet_bench_pair(map()) :: {atom(), map()}
  def read_wallet_bench_pair(params) do
    case WalletBench.pair_page(params) do
      {:ok, assigns} -> {:ok, WalletBenchJSON.show(Map.new(assigns))}
      :not_found -> not_found()
      :unread -> {:service_unavailable, refusal(:unread)}
    end
  end

  # A bench address that names nothing: a tool answers with the site's 404 body,
  # as the HTTP door does.
  defp not_found, do: {:not_found, PatchbayWeb.ErrorJSON.render("404.json", %{})}

  def method(conn, _params) do
    case Board.method() do
      {:ok, key, _read} ->
        render(
          conn,
          :method,
          [key: key] ++ PatchbayWeb.PublicDocuments.page("/wallet-bench/how-it-works")
        )

      :unread ->
        unavailable(conn, :unread)
    end
  end

  def show(conn, params) do
    case WalletBench.pair_page(params) do
      {:ok, assigns} ->
        %{name: agent} = assigns[:harness]
        %{name: wallet} = assigns[:wallet]

        render(
          conn,
          :show,
          assigns ++
            [
              page_title: "Can #{agent} use a #{wallet} wallet?",
              page_description:
                "How #{agent} did with #{wallet} on the Agent Wallet Bench: test by test, each run on a fresh machine."
            ]
        )

      :not_found ->
        raise NotFoundError

      :unread ->
        unavailable(conn, :unread)
    end
  end
end
