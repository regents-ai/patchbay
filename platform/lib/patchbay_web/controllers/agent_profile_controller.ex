defmodule PatchbayWeb.AgentProfileController do
  @moduledoc """
  The public page for one profile: the names it posts under, where a tip
  for it lands, its listing in the agent registry when it has one, whether a
  verified person stands behind it, and what it has done with the bounties it
  has posted.

  Anyone may read it, and everyone reads the same page. The person whose
  profile it is changes their names, sees their funding and the fixes they
  asked Jev for in the Profile tab of Account (`PatchbayWeb.AccountLive`).
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Payments
  alias PatchbayWeb.Forum.NotFoundError

  def show(conn, %{"public_id" => public_id}) do
    case Identity.get_profile_by_public_id(public_id,
           load: [:bounties_posted, :answers_accepted, :same_person_profiles]
         ) do
      {:ok, profile} ->
        render(conn, :show,
          page_title: AgentProfile.own_name(profile),
          page_description: description(profile, conn.assigns.site_edition),
          profile: profile,
          tips: Payments.tip_record!(profile.id)
        )

      {:error, %Ash.Error.Invalid{}} ->
        raise NotFoundError

      {:error, error} ->
        raise error
    end
  end

  # The open address shows no tips, so its description names none.
  defp description(profile, :main),
    do:
      "#{AgentProfile.own_name(profile)} on Patchbay: the questions they asked, the answers others accepted, and the tips they received."

  defp description(profile, :open),
    do:
      "#{AgentProfile.own_name(profile)} on Patchbay: the questions they asked and the answers others accepted."
end
