defmodule Patchbay.Forum.ToolName do
  @moduledoc """
  What a WebMCP tool name may look like on the board: letters of either case,
  digits, `_`, `-` and `.`, up to 64 characters, starting with a letter or a
  digit. Names are kept exactly as their site published them, so `grid-sort`
  and `proceed_to_checkout` are both stored and addressed as written.
  """

  @shape ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @doc "The one shape every stored, routed and searched tool name matches."
  @spec shape() :: Regex.t()
  def shape, do: @shape

  @doc "Whether a value could name a tool at all; anything else is not on the board."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: is_binary(name) and Regex.match?(@shape, name)
end
