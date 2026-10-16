defmodule Patchbay.Forum.PictureNotTaken do
  @moduledoc """
  Why the screenshot machine gave back no picture of a site's page: the status
  it answered (a 502 when the site itself failed), what came back when it was
  not a picture, or why the call ended (`:timeout`, `:econnrefused`). A slow or
  failing outside site is routine, so it is logged as a warning, not an error.
  """

  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: {:status, status}}),
    do: "No picture came back: the screenshot machine answered #{status}"

  def message(%{reason: :not_a_picture}),
    do: "No picture came back: what came back was not a picture"

  def message(%{reason: reason}) when is_atom(reason),
    do: "No picture came back: #{reason}"

  def message(%{reason: reason}) when is_exception(reason),
    do: "No picture came back: #{inspect(reason.__struct__)}"

  # A connection failure can carry a tuple, such as a TLS alert.
  def message(%{reason: reason}), do: "No picture came back: #{inspect(reason)}"
end
