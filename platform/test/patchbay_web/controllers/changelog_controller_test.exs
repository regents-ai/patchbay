defmodule PatchbayWeb.ChangelogControllerTest do
  use PatchbayWeb.ConnCase, async: true

  # Every dated entry is a heading in the whole Markdown answer.
  defp entry_count(conn) do
    conn
    |> put_req_header("accept", "text/markdown")
    |> get(~p"/changelog?page=2")
    |> response(200)
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "## "))
  end

  test "the pages hold every entry once, newest first, each reached from the one before",
       %{conn: conn} do
    walk = fn walk, path, seen ->
      document = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()

      entries =
        document |> LazyHTML.query(".pb-changelog__release h2") |> Enum.map(&LazyHTML.text/1)

      assert length(entries) in 1..12

      case document |> LazyHTML.query("a[rel=next]") |> LazyHTML.attribute("href") do
        [older] -> walk.(walk, older, seen ++ entries)
        [] -> seen ++ entries
      end
    end

    headings = walk.(walk, ~p"/changelog", [])
    assert length(headings) == entry_count(conn)
    assert headings == Enum.uniq(headings)

    dates = Enum.map(headings, &(~r/\d{4}-\d{2}-\d{2}/ |> Regex.run(&1) |> hd()))
    assert dates == Enum.sort(dates, :desc)
  end

  test "a page that does not exist is missing", %{conn: conn} do
    for page <- ["0", "999", "two", "1.5"] do
      assert_error_sent 404, fn -> get(conn, ~p"/changelog?#{[page: page]}") end
    end
  end
end
