defmodule PatchbayWeb.PublicDocuments do
  @moduledoc """
  Patchbay serves no document ahead of the router. Its Markdown pages are
  rendered by their own controllers, and several of them read the board, so
  `RegentAgentAccess.Plug` is told to pass every address on to its real
  pipeline.
  """

  @spec document(String.t()) :: nil
  def document(_path), do: nil
end
