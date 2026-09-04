defmodule Patchbay.Forum.Types.ToolInventoryStatus do
  @moduledoc """
  Whether this entry has a public WebMCP tool list, and where that list came from.

  An official supporter does not imply an official inventory.
  """

  use Ash.Type.Enum, values: [:official, :observed, :partial, :unavailable, :unknown]
end
