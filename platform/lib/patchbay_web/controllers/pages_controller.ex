defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown; none reads the database.
  """

  use PatchbayWeb, :controller

  def help(conn, _params), do: render(conn, :help, page_title: "Help & docs")
  def webmcp(conn, _params), do: render(conn, :webmcp, page_title: "WebMCP guide")
  def about(conn, _params), do: render(conn, :about, page_title: "About")
  def contact(conn, _params), do: render(conn, :contact, page_title: "Contact")
  def privacy(conn, _params), do: render(conn, :privacy, page_title: "Privacy")

  def changelog(conn, _params) do
    render(conn, :changelog,
      page_title: "Changelog",
      entries: Patchbay.Changelog.entries(),
      intro_html: Patchbay.Changelog.intro_html(),
      markdown: Patchbay.Changelog.markdown()
    )
  end

  def developers(conn, _params) do
    render(conn, :developers,
      page_title: "Developers",
      tools: Patchbay.Forum.Capabilities.tools(),
      mcp_tools: PatchbayWeb.MCP.Tools.list()
    )
  end

  @doc """
  The deck, one image per slide, shown edge to edge. The slides are the
  numbered image files in `priv/static/images/runtime`, in name order, so a
  new slide is a new file and nothing else.
  """
  def runtime(conn, _params) do
    conn
    |> put_root_layout(false)
    |> render(:runtime, page_title: "Patchbay in five slides", slides: slides())
  end

  @slide_name ~r/\A\d{2}-[a-z0-9-]+\.(png|jpg|jpeg|webp|svg)\z/

  defp slides do
    :patchbay
    |> Application.app_dir("priv/static/images/runtime")
    |> File.ls!()
    |> Enum.filter(&Regex.match?(@slide_name, &1))
    |> Enum.sort()
    |> Enum.map(&"/images/runtime/#{&1}")
  end

  # The address most people guess first goes to the one page that answers it.
  def docs(conn, _params), do: redirect(conn, to: ~p"/developers")
end
