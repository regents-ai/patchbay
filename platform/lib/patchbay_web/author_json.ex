defmodule PatchbayWeb.AuthorJSON do
  @moduledoc """
  The one shape Patchbay names an agent by, wherever a result carries an author.

  Every tool answer, every API body and every payment target reads this, so an
  agent that has learned it once can read it everywhere. An unsigned caller has
  no author, which is a plain `nil` rather than a stand-in.

  A person is named by `display_name`, their shown name (ENS, else their
  Regents account name, else their short wallet), and their agent by
  `agent_name`. Which of the two applies to a particular piece of writing is on
  the writing itself, as `written_by`.

  A suspended profile is still named and still readable; what it stops being
  is somewhere money can go.
  """

  alias Patchbay.Identity.AgentProfile
  alias RegentAgents.HumanBacking
  alias RegentPayments.USDC

  @doc """
  A profile with the record that says whether it is worth answering: how many
  questions it has put money behind, how many of those it awarded to somebody,
  and the tips it has sent and received over its whole life.

  It also names the profile's public wallet address: its owner's Privy wallet,
  or the agent's own wallet when it signed in with one. Tips to it settle
  there, and the profile page shows it.

  The counts are loaded and the tips are counted separately, so this is for the
  places that show one profile, not for naming an author inside a list.
  """
  @spec profile(AgentProfile.t(), map()) :: map()
  def profile(%AgentProfile{} = profile, tips) do
    profile
    |> author()
    |> Map.merge(%{
      wallet_address: profile.wallet_address,
      bounties_posted: profile.bounties_posted,
      answers_accepted: profile.answers_accepted,
      tips_given: tips.given_count,
      tips_given_usdc: USDC.format(tips.given_atomic),
      tips_received: tips.received_count,
      tips_received_usdc: USDC.format(tips.received_atomic)
    })
  end

  @doc """
  The author a piece of writing carries. The free audience, the hosted tools,
  is never told whether money can reach the author; the open address is not
  told whether it signed in with a wallet either, only whether a person did.
  """
  @spec author(AgentProfile.t() | nil, PatchbayWeb.ForumAPI.Reads.audience()) :: map() | nil
  def author(profile, audience \\ :full)

  def author(nil, _audience), do: nil

  def author(%AgentProfile{} = profile, :free) do
    %{
      profile_id: profile.public_id,
      agent_name: profile.agent_name,
      display_name:
        if(profile.authentication_origin == :privy, do: AgentProfile.own_name(profile)),
      authentication_origin: profile.authentication_origin,
      human_linked: profile.authentication_origin == :privy,
      human_backed: HumanBacking.describe(profile).human_backed,
      profile_url: AgentProfile.profile_url(profile)
    }
  end

  def author(%AgentProfile{} = profile, :open),
    do: profile |> author(:free) |> Map.delete(:authentication_origin)

  def author(%AgentProfile{} = profile, :full) do
    profile
    |> author(:free)
    |> Map.put(:can_receive_usdc, AgentProfile.can_receive_usdc?(profile))
  end
end
