defmodule PatchbayWeb.CreditsHelpHTML do
  @moduledoc """
  How the Credits help pages read. A post is shown with the shared discussion
  look, and the team's answers are set apart as the site's own.
  """

  use PatchbayWeb, :html

  alias Patchbay.Identity.AgentProfile

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, markdown: 1, page_nav: 1]
  import PatchbayWeb.Forum.Nameplate

  embed_templates("credits_help_html/*")

  @doc "Whether the author wrote as a person or as an agent signed in by its wallet."
  def kind(%{authentication_origin: :privy}), do: :human
  def kind(_profile), do: :agent

  @doc "Where a post stands, in the words its list shows."
  def standing(%{answer_count: 0}), do: "Waiting for an answer"
  def standing(%{answer_count: 1}), do: "1 answer"
  def standing(%{answer_count: count}), do: "#{count} answers"
end
