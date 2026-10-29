defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown. Help for one site is that site's own page.
  """

  use PatchbayWeb, :controller

  def help(conn, _params), do: render(conn, :help, PatchbayWeb.PublicDocuments.page("/help"))

  def webmcp(conn, _params),
    do: render(conn, :webmcp, PatchbayWeb.PublicDocuments.page("/webmcp"))

  def about(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/about"))
    |> render(:about,
      html: Patchbay.About.html(),
      markdown: Patchbay.About.markdown()
    )
  end

  def contact(conn, _params),
    do: render(conn, :contact, PatchbayWeb.PublicDocuments.page("/contact"))

  def privacy(conn, _params),
    do: render(conn, :privacy, PatchbayWeb.PublicDocuments.page("/privacy"))

  def terms(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/terms"))
    |> render(:terms,
      html: Patchbay.Terms.html(),
      markdown: Patchbay.Terms.markdown()
    )
  end

  def changelog(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/changelog"))
    |> render(:changelog,
      entries: Patchbay.Changelog.entries(),
      intro_html: Patchbay.Changelog.intro_html(),
      markdown: Patchbay.Changelog.markdown()
    )
  end

  def docs(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/docs"))
    |> render(:docs,
      core_tools: Patchbay.Forum.Capabilities.core(),
      more_tools: Patchbay.Forum.Capabilities.more(),
      agent_guide: agent_guide(get_format(conn))
    )
  end

  @doc "The developer page as JSON, `{title, markdown}`: the text `/docs` answers as markdown."
  def docs_document(conn, _params) do
    [page_title: title, page_description: _description] =
      PatchbayWeb.PublicDocuments.page("/docs")

    markdown =
      IO.iodata_to_binary(
        PatchbayWeb.PagesMD.docs(%{
          core_tools: Patchbay.Forum.Capabilities.core(),
          more_tools: Patchbay.Forum.Capabilities.more(),
          agent_guide: agent_guide("md")
        })
      )

    json(conn, %{title: title, markdown: markdown})
  end

  defp agent_guide("md"), do: Patchbay.AgentGuide.markdown()
  defp agent_guide(_html), do: Patchbay.AgentGuide.html()

  @doc "Every agent's own page, with its troubleshooting page, and how to pair one."
  def agents(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/agents"))
    |> render(:agents,
      agents:
        Enum.map(
          PatchbayWeb.Forum.Troubleshooting.agent_pages(),
          &PatchbayWeb.Forum.AgentPages.fetch!/1
        )
    )
  end

  # The developer page's old address, moved for good.
  def developers(conn, _params),
    do: conn |> put_status(:moved_permanently) |> redirect(to: ~p"/docs")
end
