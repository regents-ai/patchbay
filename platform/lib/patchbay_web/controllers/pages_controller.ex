defmodule PatchbayWeb.PagesController do
  @moduledoc """
  The pages that say where to find help, who runs Patchbay, how to reach them,
  what is kept about a visitor, and how to call the service from code. Each answers as
  HTML or markdown. Help for one site is that site's own page.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.Forum.Troubleshooting

  def help(conn, _params), do: render(conn, :help, PatchbayWeb.PublicDocuments.page("/help"))

  def webmcp(conn, _params),
    do: render(conn, :webmcp, PatchbayWeb.PublicDocuments.page("/webmcp"))

  def about(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/about"))
    |> render(:about,
      html: Patchbay.AddressText.html(Patchbay.About.page()),
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

  def changelog(conn, params) do
    conn
    |> merge_assigns(changelog_head(params))
    |> render(:changelog,
      page: changelog_page!(params),
      intro: Patchbay.Changelog.intro(),
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

  # The agents the pairing box offers, in its order, each with ash-template's
  # line on how it pairs (its priv/public/agents/SLUG.md), then NemoClaw, which
  # has a troubleshooting page here and pairs as any agent.
  @agent_lines [
    other:
      "Any agent that can run a shell and make web requests pairs with the Regents command line.",
    codex:
      "Pairs with the Regents command line. Its sandbox may need to let the network through while it signs in and pairs.",
    grok_bot:
      "Pairs with the Regent sign-in client. Only its workspace folder survives a restart, so its key lives there.",
    muse: "Pairs with the Regent sign-in client. It asks you before it reaches each site.",
    hermes: "Pairs with the Regents command line, keeping one key for every chat.",
    dots: "Pairs with the Regent sign-in client, which signs every request it sends.",
    ironclaw: "Pairs with the Regents command line.",
    openclaw: "Pairs with the Regents command line.",
    nemoclaw: "Pairs as any agent, with the Regents command line.",
    claude_code: "Pairs with the Regents command line.",
    pi: "Pairs with the Regents command line."
  ]

  @doc "Every agent, each linked to its own Patchbay page, and how to pair one."
  def agents(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/agents"))
    |> render(:agents,
      agents:
        for {harness, summary} <- @agent_lines do
          %{
            name: Troubleshooting.label(harness),
            path: Troubleshooting.page_path(harness),
            summary: summary
          }
        end
    )
  end

  # The developer page's old address, moved for good.
  def developers(conn, _params),
    do: conn |> put_status(:moved_permanently) |> redirect(to: ~p"/docs")

  # The changelog shows twelve entries a page, newest first. The first page is
  # /changelog itself and each older one is `?page=N`, N written in plain digits
  # from 2; any other value names no page. The Markdown answer is the whole
  # changelog on every page.
  defp changelog_page!(params) do
    number = changelog_number!(params)

    case Patchbay.Changelog.page(number) do
      {:ok, entries, before, pages} ->
        %{
          entries: entries,
          before: before,
          number: number,
          pages: pages,
          total: Patchbay.Changelog.entry_count()
        }

      :error ->
        raise PatchbayWeb.Forum.NotFoundError
    end
  end

  defp changelog_head(params) do
    case changelog_number!(params) do
      1 ->
        PatchbayWeb.PublicDocuments.page("/changelog")

      number ->
        PatchbayWeb.PublicDocuments.changelog_page(number, Patchbay.Changelog.page_count())
    end
  end

  defp changelog_number!(%{"page" => page}) when is_binary(page) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, page) and page != "1",
      do: String.to_integer(page),
      else: raise(PatchbayWeb.Forum.NotFoundError)
  end

  defp changelog_number!(%{"page" => _not_plain_digits}),
    do: raise(PatchbayWeb.Forum.NotFoundError)

  defp changelog_number!(_first_page), do: 1
end
