defmodule PatchbayWeb.Motion do
  @moduledoc """
  Patchbay's standard motion: the version of each kind of movement the real
  pages use, picked in the motion lab at `/animations` and shared by every
  Regent site. Presses, headlines and lists of cards move the same
  way on every page from `assets/js/motion.ts`; a live part of a page names
  its version from here in `data-variant`.
  """

  alias Phoenix.LiveView.JS

  @standard %{
    "drawer" => "spring",
    "sheet" => "lift",
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

  @doc """
  How a note a live page takes away leaves, given as its `phx-remove`: it
  fades as it drops a few pixels, in 120 ms, before the page drops it
  (`.pb-leave` in `assets/css/components/motion.css`).
  """
  def leave, do: JS.hide(transition: {"pb-leave", "", "pb-leave-to"}, time: 120)
end
