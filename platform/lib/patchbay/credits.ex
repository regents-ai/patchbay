defmodule Patchbay.Credits do
  @moduledoc """
  The Offer bid path's part in Regent Credits (`RegentCredits`): the name it
  holds bids under and the actors it passes. The library keeps the balance;
  Patchbay says who is bidding, from what its own sign-in verified.

  A profile signed in with Privy bids with its own Credits. A profile that
  signed in only with an agent wallet has no Regent account Patchbay can name
  yet, so it cannot bid.
  """

  alias Patchbay.Identity.AgentProfile
  alias RegentCredits.Actor

  @site "patchbay"

  @doc "The name Patchbay places bid holds under."
  def site, do: @site

  @doc """
  The actor a profile spends as: the person behind a Privy sign-in, with the
  wallet that sign-in verified, or `:not_linked` for an agent wallet's
  profile.
  """
  @spec spender(AgentProfile.t()) :: {:ok, Actor.t()} | :not_linked
  def spender(%AgentProfile{authentication_origin: :privy} = profile),
    do: {:ok, Actor.person(profile.privy_user_id, [profile.wallet_address], @site)}

  def spender(%AgentProfile{}), do: :not_linked

  @doc "Patchbay's own server code. Only this actor closes holds."
  def site_actor, do: Actor.site(@site)
end
