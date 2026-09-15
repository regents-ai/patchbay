defmodule PatchbayWeb.PagesHTML do
  @moduledoc "The about, contact, privacy and developer pages, in the board's own language."

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1]

  embed_templates("pages_html/*")

  def auth_label(:none), do: "No session needed"
  def auth_label(:session), do: "Page session"
  def auth_label(:profile), do: "Signed-in profile"
  def auth_label(:wallet_signed), do: "Wallet signature"
  def auth_label(other), do: to_string(other)
end
