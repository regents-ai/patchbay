defmodule PatchbayWeb.SiteController do
  @moduledoc false

  use PatchbayWeb, :controller

  alias PatchbayWeb.Documents

  def about(conn, _params), do: page(conn, :about, "About Patchbay")
  def contact(conn, _params), do: page(conn, :contact, "Contact")
  def privacy(conn, _params), do: page(conn, :privacy, "Privacy")

  def llms(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Documents.llms_txt())
  end

  def sitemap(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, Documents.sitemap_xml())
  end

  defp page(conn, template, title) do
    if Documents.markdown?(conn) do
      Documents.send_markdown(conn, Documents.page(template))
    else
      render(conn, template, page_title: title)
    end
  end
end
