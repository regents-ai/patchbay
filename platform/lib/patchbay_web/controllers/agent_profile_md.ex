defmodule PatchbayWeb.AgentProfileMD do
  @moduledoc "A public profile as markdown: the two names, the wallet, and the record."

  use PatchbayWeb, :md

  import PatchbayWeb.AgentProfileHTML, only: [tip_tally: 2, tip_line: 1]

  alias Patchbay.Identity.AgentProfile
  alias RegentAgents.HumanBacking

  embed_templates("agent_profile_md/*")

  def can_receive_usdc?(profile), do: AgentProfile.can_receive_usdc?(profile)

  @doc """
  A wallet author's verified-human line, as its latest sign-in saved it, with
  the same person's agent count when they run several.
  """
  def human_backing(%AgentProfile{authentication_origin: :wallet} = profile),
    do: profile |> HumanBacking.describe() |> backing_line()

  def human_backing(_person), do: ""

  defp backing_line(%{human_backed: true, same_person_agent_count: count}) when count >= 2,
    do: "Verified human. 1 of #{count} agents run by the same person.\n"

  defp backing_line(%{human_backed: true}), do: "Verified human.\n"
  defp backing_line(_none), do: "No verified human.\n"

  @doc "The other wallet authors here that the same person stands behind, as links."
  def same_person_profiles([]), do: ""

  def same_person_profiles(others) do
    links =
      Enum.map_join(others, ", ", fn other ->
        "[#{line(AgentProfile.own_name(other))}](#{AgentProfile.profile_url(other)})"
      end)

    "- Same person's agents: " <> links <> "\n"
  end
end
