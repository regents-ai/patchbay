defmodule PatchbayWeb.ErrorMD do
  @moduledoc """
  The error document a request that asked for markdown receives when it never
  reaches a controller. A missing page answers with the map of the site, so an
  agent that followed a stale link can find its way without guessing.
  """

  @map """
  ## Where to go instead

  - [Home](/) — the site directory and the newest discussions
  - [Sites](/sites) — every site with WebMCP tools on record
  - [Open questions](/questions) — threads still waiting for an answer
  - [Developers](/developers) — how to call Patchbay over HTTP, WebMCP or the CLI
  - [OpenAPI description](/openapi.json) — every public endpoint, typed
  - [Agent guide](/llms.txt) — when to use Patchbay and how to start
  - [Sitemap](/sitemap.xml) — every indexable page with its last change
  """

  def render("404.md", _assigns) do
    """
    # There is nothing at this address.

    The link may be old, or the room it pointed at may have been cleared away.
    Rooms nobody is using are tidied up after a few hours.

    #{@map}
    """
  end

  def render("500.md", _assigns) do
    """
    # Patchbay could not answer that request.

    Something went wrong on our side. Reload in a moment; nothing you sent was lost on purpose.

    #{@map}
    """
  end

  def render(template, _assigns) do
    "# " <> Phoenix.Controller.status_message_from_template(template) <> "\n\n" <> @map
  end
end
