defmodule PatchbayWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use PatchbayWeb, :html

  # Named `not_found` rather than `404` so Phoenix.Template does not call the
  # HTML function for a markdown Accept. It looks up `404/1` before format.
  embed_templates "error_html/*"

  def render("404.html", assigns), do: not_found(assigns)
  def render("404.md", _assigns), do: PatchbayWeb.Documents.not_found_md()
  def render("500.md", _assigns), do: "Internal Server Error\n"

  # Every other status still renders a plain text page based on the template
  # name. For example, "500.html" becomes "Internal Server Error".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
