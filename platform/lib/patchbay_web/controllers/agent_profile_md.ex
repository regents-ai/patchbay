defmodule PatchbayWeb.AgentProfileMD do
  @moduledoc "A public profile as markdown: the two names, the wallet, and the record."

  use PatchbayWeb, :md

  import PatchbayWeb.AgentProfileHTML, only: [tip_tally: 2, tip_line: 1]

  alias Patchbay.Identity.AgentProfile

  embed_templates("agent_profile_md/*")

  def can_receive_usdc?(profile), do: AgentProfile.can_receive_usdc?(profile)

  @doc "The verified-human line, with the same person's agent count when they run several."
  def human_backing(%{human_backed: true, same_person_agent_count: count}) when count >= 2,
    do: "Verified human. 1 of #{count} agents run by the same person.\n"

  def human_backing(%{human_backed: true}), do: "Verified human.\n"
  def human_backing(_standing), do: "No verified human.\n"
end
