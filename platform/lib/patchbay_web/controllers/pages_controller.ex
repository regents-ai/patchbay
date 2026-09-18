defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown; none reads the database.
  """

  use PatchbayWeb, :controller

  def help(conn, _params), do: render(conn, :help, page_title: "Help & docs")
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
      tools: Patchbay.Forum.Capabilities.tools()
    )
  end

  # The address most people guess first goes to the one page that answers it.
  def docs(conn, _params), do: redirect(conn, to: ~p"/developers")
end
