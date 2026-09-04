defmodule PatchbayWeb.SiteControllerTest do
  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.Documents

  test "about, contact and privacy are public pages with real copy", %{conn: conn} do
    for {path, heading, copy} <- [
          {"/about", "About Patchbay", Documents.about_html()},
          {"/contact", "Contact", Documents.contact_html()},
          {"/privacy", "Privacy", Documents.privacy_html()}
        ] do
      html = conn |> get(path) |> html_response(200)
      assert html =~ heading
      assert String.length(Enum.join(copy, " ")) >= 500
    end

    assert conn |> get("/contact") |> html_response(200) =~ "build@regents.sh"
  end

  test "the homepage publishes identity metadata and JSON-LD", %{conn: conn} do
    conn = get(conn, "/")
    html = html_response(conn, 200)

    assert html =~ ~s(rel="canonical" href="https://patchbay.help")
    assert html =~ ~s(property="og:image" content="https://patchbay.help/apple-touch-icon.png")
    assert html =~ "application/ld+json"
    assert html =~ "SoftwareApplication"
    assert html =~ "Organization"
    assert html =~ "build@regents.sh"
    assert html =~ "The board and live demo are free to read"
    assert vary_accept?(conn)
  end

  test "the share image is a static file Plug.Static serves", %{conn: conn} do
    conn = get(conn, "/apple-touch-icon.png")

    assert conn.status == 200
    assert response_content_type(conn, :png) =~ "image/png"
    assert byte_size(conn.resp_body) > 1_000
  end

  test "Accept text/markdown serves the homepage as markdown", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/")

    assert conn.status == 200
    assert markdown_response?(conn)
    assert vary_accept?(conn)
    assert conn.resp_body =~ "# Patchbay"
    assert conn.resp_body =~ "## When to use this"
    assert conn.resp_body =~ "llms.txt"
  end

  test "Accept text/plain serves public pages as the markdown source", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/plain")
      |> get("/about")

    assert conn.status == 200
    assert plain_response?(conn)
    assert vary_accept?(conn)
    assert conn.resp_body =~ "# About Patchbay"
    assert conn.resp_body =~ "build@regents.sh"
  end

  test "about, contact and privacy answer markdown", %{conn: conn} do
    for path <- ["/about", "/contact", "/privacy"] do
      conn =
        conn
        |> put_req_header("accept", "text/markdown")
        |> get(path)

      assert conn.status == 200
      assert markdown_response?(conn)
      assert vary_accept?(conn)
    end
  end

  test "llms.txt tells agents when to use Patchbay", %{conn: conn} do
    conn = get(conn, "/llms.txt")

    assert conn.status == 200
    assert response_content_type(conn, :txt) =~ "text/plain"
    assert conn.resp_body =~ "## When to use this"
    assert conn.resp_body =~ "get_patchbay_help"
    assert conn.resp_body =~ "not a remote MCP"
    assert vary_accept?(conn)
  end

  test "sitemap.xml lists the public documents", %{conn: conn} do
    conn = get(conn, "/sitemap.xml")
    xml = response(conn, 200)

    assert response_content_type(conn, :xml) =~ "xml"
    assert xml =~ "<urlset"
    assert xml =~ "<loc>"
    assert xml =~ "/about"
    assert xml =~ "/contact"
    assert xml =~ "/privacy"
    assert xml =~ "/llms.txt"
    assert xml =~ "/agent-setup"
    assert xml =~ "/webmcp/rooms/skill-uplift"
    assert vary_accept?(conn)
  end

  test "robots.txt points crawlers at the sitemap", %{conn: conn} do
    body = conn |> get("/robots.txt") |> response(200)

    assert body =~ "Sitemap: https://patchbay.help/sitemap.xml"
  end
end
