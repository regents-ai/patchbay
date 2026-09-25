defmodule PatchbayWeb.Motion do
  @moduledoc """
  Patchbay's standard motion: the version of each kind of movement the real
  pages use, picked in the motion lab at `/animations`. Presses, headlines
  and lists of cards move the same way on every page from `motion.js`; a live
  part of a page names its version from here.
  """

  @standard %{
    "drawer" => "spring",
    "sheet" => "spring",
    "menu" => "pop",
    "note" => "peel",
    "toast" => "pop",
    "list" => "bounce",
    "count" => "roll",
    "stamp" => "thunk",
    "tabs" => "glide",
    "headline" => "rise",
    "grid" => "cascade"
  }

  @doc "Every part's standard version."
  def standard, do: @standard

  @doc "The standard version of one part, such as `\"list\"`."
  def standard(part), do: Map.fetch!(@standard, part)
end
