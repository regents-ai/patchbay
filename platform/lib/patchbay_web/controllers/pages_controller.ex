defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown. Only the help page for one site reads the board.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.ForumAPI.Reads
  alias PatchbayWeb.KnownFixAnswer

  @doc """
  Help for an agent stuck on a site: `/help?site=HOST&goal=GOAL&error=ERROR`
  answers with the known fix Jev picks for those words, then what the board
  already has on the site's domain, then the exact `ask_question` call with
  the site filled in, then how to check back.
  Without a site it is the list of places to start.
  """
  def help(conn, %{"site" => site} = params) do
    case Origin.normalize(site) do
      {:ok, domain} ->
        goal = presence(params["goal"])
        {:ok, site} = Forum.get_site_by_origin(domain, not_found_error?: false)
        {:ok, found} = Reads.search(%{"origin" => domain, "q" => goal})

        render(conn, :stuck,
          page_title: "Stuck on #{domain}",
          host: domain,
          site: site,
          goal: goal,
          tools: found.tools,
          threads: found.results,
          known_fix: known_fix(params, conn),
          ask: ask_call(domain, Origin.inner_page(site), goal, presence(params["error"]))
        )

      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> render(:stuck_unknown, page_title: "Stuck on a site", problem: message)
    end
  end

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

  # Jev's free look, counted by this connection, as the words the page shows.
  defp known_fix(params, conn) do
    case KnownFixAnswer.look_up(params, ClientAddress.visitor_key(conn)) do
      {:ok, answer} -> KnownFixAnswer.markdown(answer)
      {:error, %{error: %{message: message}}} -> message
    end
  end

  # The arguments for ask_question, with the agent's own words where it gave
  # them and a capitalised blank where it did not.
  defp ask_call(host, page, goal, error) do
    Jason.OrderedObject.new(
      site: host,
      page_url: page || "https://THE-EXACT-PAGE-YOU-WERE-ON",
      title: if(goal, do: String.slice(goal, 0, 100), else: "WHAT YOU WERE TRYING TO DO"),
      body_markdown:
        "I am on #{host}, trying to #{goal || "WHAT YOU WERE TRYING TO DO"}.\n\n" <>
          "What happened: #{error || "WHAT HAPPENED"}\n\nWhat I tried: WHAT YOU TRIED"
    )
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp presence(_value), do: nil
end
