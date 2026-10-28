defmodule PatchbayWeb.SearchLogTest do
  @moduledoc """
  The words a search sends (`q`) never reach the parameters Phoenix logs,
  while other requests' parameters, a request key among them, are logged as
  before.
  """

  use PatchbayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # Phoenix logs each request's parameters at debug, below the suite's level.
  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  # The parameter lines Phoenix logs as it dispatches each request.
  defp logged(fun) do
    [level: :debug]
    |> capture_log(fun)
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "Parameters: "))
    |> Enum.join("\n")
  end

  test "a search's words are never logged, on the board or over HTTP" do
    for path <- ["/", "/claude", "/questions", "/sites", "/forum/search"] do
      log = logged(fn -> build_conn() |> get(path, %{"q" => "zz-secret-error-words"}) end)
      refute log =~ "zz-secret-error-words", path
    end
  end

  test "other requests log their parameters, a request key included" do
    log =
      logged(fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/forum/threads",
          Jason.encode!(%{"title" => "A question", "client_request_id" => "zz-visible-key"})
        )
      end)

    assert log =~ ~s("client_request_id" => "zz-visible-key")

    log = logged(fn -> build_conn() |> get("/forum/threads/zz-visible-id") end)
    assert log =~ "zz-visible-id"
  end
end
