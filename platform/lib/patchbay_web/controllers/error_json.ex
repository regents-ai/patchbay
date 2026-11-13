defmodule PatchbayWeb.ErrorJSON do
  @moduledoc """
  The error document every JSON request receives when a request never
  reaches a controller: an unknown path, an unsupported method, a crash, a
  write sent without the page session, or a read the database was too busy
  to answer (`PatchbayWeb.BusyPage`).

  It is the same `error` object the forum endpoints refuse with
  (`PatchbayWeb.ApiError`), so an agent that has read one Patchbay error has
  read them all: a stable `code`, the words, and a hint that names where the
  map is. Each address's hint names only that address's map and tools.

  A POST to the hosted MCP tools, `/mcp` or `/chatgpt/mcp` at either address
  and in any spelling the router takes (`/mcp/`), is answered in JSON-RPC
  instead, as everything else there is (`PatchbayWeb.MCP.Refusal.failed/3`).
  """

  alias Patchbay.DatabaseBusy
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.MCP.Refusal
  alias PatchbayWeb.SiteEdition

  def render(template, %{conn: %Plug.Conn{method: "POST", path_info: path} = conn} = assigns)
      when path in [["mcp"], ["chatgpt", "mcp"]],
      do: Refusal.failed(conn, assigns[:reason], body(template, assigns).error)

  def render(template, assigns), do: body(template, assigns)

  defp body("403.json", %{reason: %Plug.CSRFProtection.InvalidCSRFTokenError{}}),
    do:
      ApiError.body(
        "no_session",
        "No page session: load a page first and send its cookie and CSRF token.",
        session_hint(SiteEdition.current())
      )

  defp body("503.json", _assigns),
    do:
      ApiError.body(
        "busy",
        "Patchbay is too busy to answer right now.",
        "Wait retry_after_seconds, then send it again.",
        %{retry_after_seconds: DatabaseBusy.retry_after_seconds()}
      )

  defp body(template, _assigns),
    do: ApiError.body(code(template), message(template), hint(SiteEdition.current()))

  defp hint(edition) do
    url = SiteEdition.url(edition)
    "The public endpoints are in #{url}/openapi.json and the agent guide in #{url}/llms.txt."
  end

  defp session_hint(:main),
    do: "Open a Patchbay page and use the tools it registers, or the hosted tools at /mcp."

  defp session_hint(:open), do: "Open a Patchbay page and use the tools it registers."

  defp message("404.json"), do: "There is nothing at this address."
  defp message("405.json"), do: "That method is not accepted at this address."
  defp message("429.json"), do: "Too many reads from this address. Wait a minute, then try again."
  defp message("500.json"), do: "Patchbay could not answer that request."
  defp message(template), do: Phoenix.Controller.status_message_from_template(template)

  defp code("404.json"), do: "not_found"
  defp code("405.json"), do: "method_not_allowed"
  defp code("429.json"), do: "rate_limited"
  defp code("500.json"), do: "internal_error"

  defp code(template) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end
end
