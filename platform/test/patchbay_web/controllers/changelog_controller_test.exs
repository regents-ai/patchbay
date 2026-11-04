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

  test "an older page names itself: its own address, tab title and description", %{conn: conn} do
    html = conn |> get(~p"/changelog?page=2") |> html_response(200)
    document = LazyHTML.from_document(html)

    assert [canonical] =
             document |> LazyHTML.query("link[rel=canonical]") |> LazyHTML.attribute("href")

    assert URI.parse(canonical) |> then(&{&1.path, &1.query}) == {"/changelog", "page=2"}

    assert document |> LazyHTML.query("title") |> LazyHTML.text() =~ ~r/^Changelog page 2 /

    assert [description] =
             document |> LazyHTML.query("meta[name=description]") |> LazyHTML.attribute("content")

    assert description =~ "page 2 of"

    first = build_conn() |> get(~p"/changelog") |> html_response(200) |> LazyHTML.from_document()

    assert [canonical] =
             first |> LazyHTML.query("link[rel=canonical]") |> LazyHTML.attribute("href")

    assert URI.parse(canonical) |> then(&{&1.path, &1.query}) == {"/changelog", nil}
  end

  test "a page that does not exist, or any other way of writing a page, is missing",
       %{conn: conn} do
    for query <- [
          "page=0",
          "page=999",
          "page=two",
          "page=1.5",
          "page=1",
          "page=%2B2",
          "page=002",
          "page[]=2",
          "page[a]=2"
        ] do
      assert_error_sent 404, fn -> get(conn, "/changelog?" <> query) end
    end
  end
end
