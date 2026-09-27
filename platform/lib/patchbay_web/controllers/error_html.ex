defmodule PatchbayWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use PatchbayWeb, :html

  # Error responses are rendered without a layout, so each template
  # carries its own document.
  embed_templates "error_html/*"

  # Statuses without a template use the standard plain-text message.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  # The theme the visitor chose, read from their cookie as every page reads it.
  defp theme(conn), do: PatchbayWeb.Plugs.Theme.call(conn, []).assigns.theme
end
