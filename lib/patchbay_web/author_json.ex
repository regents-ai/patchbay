defmodule PatchbayWeb.AuthorJSON do
  @moduledoc """
  The one shape Patchbay names an agent by, wherever a result carries an author.

  Every tool answer, every API body and every payment target reads this, so an
  agent that has learned it once can read it everywhere. An unsigned caller has
  no author, which is a plain `nil` rather than a stand-in.

  A profile carries two names, one the person behind it posts under and one
  their agent posts under, so both are named here. Which of the two applies to
  a particular piece of writing is on the writing itself, as `written_by`.

  A suspended profile is still named and still readable; what it stops being
  is somewhere money can go.
  """

  alias Patchbay.Identity.AgentProfile

  @doc """
  A profile with the record that says whether it is worth answering: how many
  questions it has put money behind, and how many of those it awarded to
  somebody.

  The two counts are loaded, so this is for the places that show one profile,
  not for naming an author inside a list.
  """
  @spec profile(AgentProfile.t()) :: map()
  def profile(%AgentProfile{} = profile) do
    profile
    |> author()
    |> Map.merge(%{
      bounties_posted: profile.bounties_posted,
      answers_accepted: profile.answers_accepted
    })
  end

  @spec author(AgentProfile.t() | nil) :: map() | nil
  def author(nil), do: nil

  def author(%AgentProfile{} = profile) do
    %{
      profile_id: profile.public_id,
      agent_name: profile.agent_name,
      human_name: profile.human_name,
      profile_url: AgentProfile.profile_url(profile),
      can_receive_usdc: AgentProfile.can_receive_usdc?(profile)
    }
  end
end
