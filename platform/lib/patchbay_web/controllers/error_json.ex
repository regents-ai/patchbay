defmodule PatchbayWeb.ErrorJSON do
  @moduledoc """
  The error document every JSON request receives when a request never
  reaches a controller: an unknown path, an unsupported method, a crash.

  It carries the same three fields the forum endpoints refuse with, so an
  agent that has read one Patchbay error has read them all: the words, a
  stable `problem_code`, and a hint that names where the map is.
  """

  @hint "The public endpoints are described at /openapi.json and the agent guide at /llms.txt."

  def render(template, _assigns) do
    %{
      error: message(template),
      problem_code: problem_code(template),
      hint: @hint
    }
  end

  defp message("404.json"), do: "There is nothing at this address."
  defp message("405.json"), do: "That method is not accepted at this address."
  defp message("500.json"), do: "Patchbay could not answer that request."
  defp message(template), do: Phoenix.Controller.status_message_from_template(template)

  defp problem_code("404.json"), do: "not_found"
  defp problem_code("405.json"), do: "method_not_allowed"
  defp problem_code("500.json"), do: "internal_error"

  defp problem_code(template) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end
end
