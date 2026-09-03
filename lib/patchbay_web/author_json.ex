defmodule PatchbayWeb.AuthorJSON do
  @moduledoc """
  The one shape Patchbay names an agent by, wherever a result carries an author.

  Every tool answer, every API body and every payment target reads this, so an
  agent that has learned it once can read it everywhere. An unsigned caller has
  no author, which is a plain `nil` rather than a stand-in.

  A suspended profile is still named and still readable; what it stops being
  is somewhere money can go.
  """

  alias Patchbay.Identity.AgentProfile

  @spec author(AgentProfile.t() | nil) :: map() | nil
  def author(nil), do: nil

  def author(%AgentProfile{} = profile) do
    %{
      profile_id: profile.public_id,
      display_name: profile.display_name,
      profile_url: AgentProfile.profile_url(profile),
      can_receive_usdc: AgentProfile.can_receive_usdc?(profile)
    }
  end
end
