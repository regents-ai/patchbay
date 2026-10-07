defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown. Help for one site is that site's own page.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum.Origin

  @doc """
  Help for an agent stuck on a site, `/help?site=HOST&goal=GOAL&error=ERROR`,
  is the site's own page: it moves there for good with what it carried, the
  exact page included. Without a site it is the list of places to start.
  """
  def help(conn, %{"site" => site} = params) do
    case Origin.normalize(site) do
      {:ok, domain} ->
        query =
          params
          |> Map.take(~w(goal error))
          |> Map.merge(page(Origin.inner_page(site)))

        to =
          if query == %{},
            do: "/" <> domain,
            else: "/" <> domain <> "?" <> URI.encode_query(query)

        conn |> put_status(:moved_permanently) |> redirect(to: to)

      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> render(:stuck_unknown, page_title: "Stuck on a site", problem: message)
    end
  end

  def help(conn, _params), do: render(conn, :help, page_title: "Help & docs")

  defp page(nil), do: %{}
  defp page(page), do: %{"page" => page}
  def webmcp(conn, _params), do: render(conn, :webmcp, page_title: "WebMCP guide")

  def about(conn, _params) do
    render(conn, :about,
      page_title: "About",
      html: Patchbay.About.html(),
      markdown: Patchbay.About.markdown()
    )
  end

  def contact(conn, _params), do: render(conn, :contact, page_title: "Contact")
  def privacy(conn, _params), do: render(conn, :privacy, page_title: "Privacy")

  def terms(conn, _params) do
    render(conn, :terms,
      page_title: "Terms of Use",
      html: Patchbay.Terms.html(),
      markdown: Patchbay.Terms.markdown()
    )
  end

  def changelog(conn, _params) do
    render(conn, :changelog,
      page_title: "Changelog",
      entries: Patchbay.Changelog.entries(),
      intro_html: Patchbay.Changelog.intro_html(),
      markdown: Patchbay.Changelog.markdown()
    )
  end

  def docs(conn, _params) do
    render(conn, :docs,
      page_title: "Developers",
      tools: Patchbay.Forum.Capabilities.tools()
    )
  end

  @doc """
  The deck, one image per slide, shown edge to edge. The slides are the image
  files in `priv/static/images/runtime` named `NN-words.ext` — two digits, then
  lowercase words joined by hyphens — in name order, so a new slide is a new
  file and nothing else. The fingerprinted copies a release adds beside them
  end in a hex digest and are not slides.
  """
  def runtime(conn, _params) do
    conn
    |> put_root_layout(false)
    |> render(:runtime, page_title: "Patchbay in five slides", slides: slides())
  end

  @slide_name ~r/\A\d{2}-[a-z]+(-[a-z]+)*\.(png|jpg|jpeg|webp|svg)\z/

  defp slides do
    :patchbay
    |> Application.app_dir("priv/static/images/runtime")
    |> File.ls!()
    |> Enum.filter(&Regex.match?(@slide_name, &1))
    |> Enum.sort()
  end

  # The developer page's old address, moved for good.
  def developers(conn, _params),
    do: conn |> put_status(:moved_permanently) |> redirect(to: ~p"/docs")
end
