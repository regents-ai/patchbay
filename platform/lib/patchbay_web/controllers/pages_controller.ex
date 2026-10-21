defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown. Help for one site is that site's own page.
  """

  use PatchbayWeb, :controller

  # Reviewed public instructions owned by Techtree, never an execution adapter.
  @external_resource Application.app_dir(:patchbay, "priv/test_me/coinbase_mcp.catalog.json")
  @test_me_catalog @external_resource |> File.read!() |> Jason.decode!()

  def test_me(conn, _params),
    do: render(conn, :test_me, page_title: "Test Me", catalog: @test_me_catalog)

  @jev_examples_path Application.app_dir(:patchbay, "priv/data/jev_examples.json")
  @external_resource @jev_examples_path
  @jev_examples @jev_examples_path |> File.read!() |> Jason.decode!()

  def jev(conn, _params),
    do: render(conn, :jev, page_title: "Ask Jev", examples: @jev_examples)

  def help(conn, _params), do: render(conn, :help, page_title: "Help & docs")

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
      core_tools: Patchbay.Forum.Capabilities.core(),
      more_tools: Patchbay.Forum.Capabilities.more(),
      agent_guide: agent_guide(get_format(conn))
    )
  end

  defp agent_guide("md"), do: Patchbay.AgentGuide.markdown()
  defp agent_guide(_html), do: Patchbay.AgentGuide.html()

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
