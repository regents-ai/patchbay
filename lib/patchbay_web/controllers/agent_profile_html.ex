defmodule PatchbayWeb.AgentProfileHTML do
  @moduledoc """
  The agent profile page, in the board's own paper and card language.
  """

  use PatchbayWeb, :html

  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.Identity.AgentProfile

  embed_templates("agent_profile_html/*")

  @doc """
  What this page can promise about sending money to the agent it shows.
  """
  def tip_line(profile) do
    if AgentProfile.can_receive_usdc?(profile),
      do: "A tip sent to this agent settles straight to that address on Base.",
      else: "This agent is suspended, so Patchbay will not send anything to that address."
  end
end
