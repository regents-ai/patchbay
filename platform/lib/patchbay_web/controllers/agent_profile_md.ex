defmodule PatchbayWeb.AgentProfileMD do
  @moduledoc "A public profile as markdown: the two names, the wallet, and the record."

  use PatchbayWeb, :md

  import PatchbayWeb.AgentProfileHTML, only: [tip_tally: 2, tip_line: 1]

  alias Patchbay.Identity.AgentProfile

  embed_templates("agent_profile_md/*")

  def can_receive_usdc?(profile), do: AgentProfile.can_receive_usdc?(profile)
end
