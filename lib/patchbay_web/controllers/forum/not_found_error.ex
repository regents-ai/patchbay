defmodule PatchbayWeb.Forum.NotFoundError do
  @moduledoc """
  Raised when a board address names a site, tool, or report that is not there.
  """

  defexception message: "that page is not on the board", plug_status: 404
end
