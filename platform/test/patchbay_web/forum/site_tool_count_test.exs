defmodule PatchbayWeb.Forum.SiteToolCountTest do
  @moduledoc """
  A site's tool count has one source: what Patchbay's own check read, on the
  site's front page and every page the directory lists under its domain. The
  directory, the board and the JSON at /sites give the same count, and a site
  Patchbay has not checked says Not checked on all three. A listed page on
  another address of the site, such as `web.autocad.com`, is read by the
  site's check and counted on its one board. The board's Address filter lists
  the posts about one address of the site, `www.` folded into the bare name.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.SiteDirectory
  alias Patchbay.PageSite

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp document(conn, path),
    do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp texts(document, selector),
    do: document |> LazyHTML.query(selector) |> Enum.map(&squish(LazyHTML.text(&1)))

  defp markdown(path),
    do: build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

  defp json_row(q, host) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> get(~p"/sites?#{[q: q]}")
    |> json_response(200)
    |> Map.fetch!("sites")
    |> Enum.find(&(&1["host"] == host))
  end

  # A check of `domain` through its own job, of a site answering from `pages`.
  defp real_check!(domain, pages) do
    PageSite.serve(pages)
    Forum.refresh_site_check!(domain)
    Oban.drain_queue(queue: :site_checks)
  end

  # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
  defp ask!(site, title, page_url) do
    Forum.ask_question!(
      %{
        site_id: site.id,
        browser_session_id: Ash.UUID.generate(),
        title: title,
        thread_kind: :help_needed,
        body_markdown: "The page answers an empty list after a search.",
        page_url: page_url
      },
      authorize?: false
    )
  end

  test "a checked site shows the same count on the directory and its board", %{conn: conn} do
    Forum.register_site!("openai.com")

    real_check!("openai.com", %{
      "/" => PageSite.with_tool("search_openai"),
      "/showcase" => PageSite.with_tool("list_apps")
    })

    row = json_row("openai", "openai.com")
    assert %{"tools" => 2, "checked_at" => checked_at} = row
    assert is_binary(checked_at)

    assert row["tool_inventory"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
             ~w(list_apps search_openai)

    directory = document(conn, ~p"/sites?q=openai")
    assert text(directory, "tr[id='directory-openai.com'] .pb-directory-count") == "2"
    assert markdown(~p"/sites?q=openai") =~ "](https://openai.com/) | 2 |"

    board = document(build_conn(), "/openai.com")
    assert text(board, "#pb-site-standing .pb-standing-tools") =~ ~r/^2 tools · checked/
    assert text(board, ".pb-site-agent-count") == "Agents see 2 WebMCP Tools"
    assert texts(board, "#pb-site-tools .pb-tool-row-name") == ~w(list_apps search_openai)
    assert markdown("/openai.com") =~ "## Status\n\n2 tools, checked"
  end

  test "an unchecked site says Not checked on the directory, its board and the JSON",
       %{conn: conn} do
    host = "dogechain.info"
    Forum.register_site!(host)

    directory = document(conn, ~p"/sites?#{[q: host]}")
    assert text(directory, "tr[id='directory-#{host}'] .pb-directory-count") == "Not checked"
    assert markdown(~p"/sites?#{[q: host]}") =~ "| Not checked | [0](/#{host}) | Not checked |"

    assert %{"tools" => nil, "tool_inventory" => nil, "checked_at" => nil} = json_row(host, host)

    board = document(build_conn(), "/" <> host)
    assert text(board, "#pb-site-standing .pb-standing-tools") == "Not checked"
    refute text(board, ".pb-site-agent-count") =~ ~r/\d/
    assert markdown("/" <> host) =~ "## Status\n\nNot checked."
  end

  test "a listed page on another address of the site is checked and counted on its board" do
    assert SiteDirectory.pages("autocad.com") == ["https://web.autocad.com/login"]
    Forum.register_site!("autocad.com")

    real_check!("autocad.com", %{
      "/" => PageSite.without_tools(),
      "/login" => PageSite.with_tool("open_drawing")
    })

    board = document(build_conn(), "/autocad.com")
    assert text(board, "#pb-site-standing .pb-standing-tools") =~ ~r/^1 tool · checked/
    assert text(board, "#pb-site-tools .pb-tool-row-name") == "open_drawing"
    assert text(board, "#pb-site-tools .pb-tool-row-meta") =~ "web.autocad.com/login"

    assert %{"tools" => 1} = json_row("autocad", "web.autocad.com")
    assert build_conn() |> get("/web.autocad.com") |> redirected_to(301) == "/autocad.com"
  end

  test "the Address filter lists a post under its own address, which its row names" do
    site = Forum.register_site!("autocad.com")
    ask!(site, "Drawings will not open in the web app", "https://web.autocad.com/login")
    ask!(site, "The pricing page shows no plans", "https://autocad.com/pricing")
    ask!(site, "Nothing named a page", nil)

    board = document(build_conn(), "/autocad.com")

    assert texts(board, "#pb-address-filter-select option") ==
             ["All", "autocad.com", "web.autocad.com"]

    # Each row names the address its post is about, or the site for a post
    # that names no page: on the live first page and on a filtered one.
    rows = fn document ->
      document
      |> LazyHTML.query("#pb-site-posts .pb-row")
      |> Enum.map(&{text(&1, ".pb-row-title"), text(&1, ".pb-site-chip")})
      |> Enum.sort()
    end

    assert rows.(board) == [
             {"Drawings will not open in the web app", "web.autocad.com"},
             {"Nothing named a page", "autocad.com"},
             {"The pricing page shows no plans", "autocad.com"}
           ]

    filtered = &rows.(document(build_conn(), ~p"/autocad.com?#{[address: &1]}"))

    assert filtered.("web.autocad.com") ==
             [{"Drawings will not open in the web app", "web.autocad.com"}]

    assert filtered.("autocad.com") == [{"The pricing page shows no plans", "autocad.com"}]

    [_status, discussions] =
      ~p"/autocad.com?#{[address: "web.autocad.com"]}"
      |> markdown()
      |> String.split("## Discussions", parts: 2)

    assert discussions =~ "Drawings will not open in the web app"
    refute discussions =~ "The pricing page shows no plans"
  end

  test "www folds into the bare name, on the post and in the filter" do
    site = Forum.register_site!("autocad.com")
    ask!(site, "The www page loses the basket", "https://www.autocad.com/store")

    board = document(build_conn(), ~p"/autocad.com?#{[address: "www.autocad.com"]}")

    assert texts(board, "#pb-address-filter-select option") == ["All", "autocad.com"]
    assert texts(board, "#pb-address-filter-select option[selected]") == ["autocad.com"]

    assert text(board, "#pb-site-posts .pb-row-title") == "The www page loses the basket"
  end
end
