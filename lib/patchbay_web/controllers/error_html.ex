defmodule PatchbayWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use PatchbayWeb, :html

  # Error responses are rendered without a layout, so the not-found page below
  # carries its own document.
  embed_templates "error_html/*"

  # Every other status still renders a plain text page based on the template
  # name. For example, "500.html" becomes "Internal Server Error".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
