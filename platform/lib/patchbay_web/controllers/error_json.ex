defmodule PatchbayWeb.ErrorJSON do
  @moduledoc """
  The error document every JSON request receives when a request never
  reaches a controller: an unknown path, an unsupported method, a crash, or
  a write sent without the page session.

  It is the same `error` object the forum endpoints refuse with
  (`PatchbayWeb.ApiError`), so an agent that has read one Patchbay error has
  read them all: a stable `code`, the words, and a hint that names where the
  map is.
  """

  alias PatchbayWeb.ApiError

  @hint "The public endpoints are described at /openapi.json and the agent guide at /llms.txt."

  def render("403.json", %{reason: %Plug.CSRFProtection.InvalidCSRFTokenError{}}),
    do:
      ApiError.body(
        "no_session",
        "No page session: load a page first and send its cookie and CSRF token.",
        "Open a Patchbay page and use the tools it registers, or the hosted tools at /mcp."
      )

  def render(template, _assigns), do: ApiError.body(code(template), message(template), @hint)

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
