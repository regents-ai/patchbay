defmodule PatchbayWeb.ErrorHTMLTest do
  use PatchbayWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html as a styled page with a way home" do
    html = render_to_string(PatchbayWeb.ErrorHTML, "404", "html", [])

    assert html =~ "There is nothing at this address."
    assert html =~ ~s{class="pb-error"}
    assert html =~ ~r{<link rel="stylesheet" href="/assets/css/app.css[^"]*">}
    assert html =~ ~r{<a class="pb-cta" href="/">\s*Back to reports\s*</a>}
    assert html =~ ~s(href="/llms.txt")
    assert html =~ ~s(href="/sitemap.xml")
    assert html =~ ~s(href="/contact")
    assert html =~ ~s(href="/privacy")
  end

  test "an unknown address renders the styled not-found page", %{conn: conn} do
    conn = get(conn, "/no-such-page")

    assert html_response(conn, 404) =~ "There is nothing at this address."
    assert html_response(conn, 404) =~ ~s(href="/llms.txt")
    assert vary_accept?(conn)
  end

  test "an unknown address answers markdown with recovery links", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/no-such-page")

    assert conn.status == 404
    assert markdown_response?(conn)
    assert conn.resp_body =~ "llms.txt"
    assert conn.resp_body =~ "sitemap.xml"
    assert conn.resp_body =~ "/about"
    assert conn.resp_body =~ "/contact"
    assert conn.resp_body =~ "/privacy"
    assert vary_accept?(conn)
  end

  test "renders 500.html" do
    assert render_to_string(PatchbayWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
