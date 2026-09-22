defmodule PatchbayWeb.AgentProfileController do
  @moduledoc """
  The public page for one profile: the two names it is known by, where a tip
  for it lands, and what it has done with the bounties it has posted.

  Anyone may read it. Only the person whose page it is sees the two controls
  that change the names, and only their own page will accept them, so a rename
  is always a rename of oneself. Only they see their Patchbay Credits, what
  they have paid and bought, and the agents paired with them, and only they
  can give out a code to pair another or unpair one.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Identity.Pairing
  alias Patchbay.Payments
  alias Patchbay.Payments.Credits
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.NotFoundError

  def show(conn, %{"public_id" => public_id}) do
    render_profile(conn, public_id, [])
  end

  @doc """
  Changes one of the two names on the visitor's own profile.

  The half being renamed comes from the form rather than from the URL, and the
  profile is the one that is signed in rather than the one on screen, so there
  is nothing in the request that could aim a rename at somebody else.
  """
  def rename(conn, %{"public_id" => public_id} = params) do
    case rename_half(conn, params) do
      :ok -> redirect(conn, to: ~p"/agents/#{public_id}")
      {:error, said} -> render_profile(conn, public_id, problem: said)
    end
  end

  @doc """
  Gives the signed-in person a new code to pair an agent with, and shows it
  once, on their own page. Like a rename, it is always for oneself.
  """
  def pair(%{assigns: %{current_profile: nil}} = conn, _params),
    do: redirect(conn, to: ~p"/profile")

  def pair(%{assigns: %{current_profile: person}} = conn, _params) do
    case Pairing.issue(person) do
      {:ok, issued} ->
        render_profile(conn, person.public_id, pairing: issued)

      {:error, _refused} ->
        render_profile(conn, person.public_id,
          pairing_said: "A code could not be made just now. Try again in a moment."
        )
    end
  end

  @doc "Unpairs one of the signed-in person's own agents."
  def unpair(%{assigns: %{current_profile: nil}} = conn, _params),
    do: redirect(conn, to: ~p"/profile")

  def unpair(%{assigns: %{current_profile: person}} = conn, params) do
    case Pairing.unpair(person, params["agent"] || "") do
      {:ok, _unpaired} ->
        redirect(conn, to: ~p"/agents/#{person.public_id}" <> "#patchbay-agents")

      {:error, _refused} ->
        render_profile(conn, person.public_id, pairing_said: "That agent is not paired with you.")
    end
  end

  defp rename_half(%{assigns: %{current_profile: nil}}, _params) do
    {:error, "Sign in to change your names."}
  end

  defp rename_half(conn, %{"half" => "human", "name" => name}) do
    profile = conn.assigns.current_profile

    apply_rename(Identity.rename_human(profile, %{human_name: name}, actor: profile))
  end

  defp rename_half(conn, %{"half" => "agent", "name" => name}) do
    profile = conn.assigns.current_profile

    apply_rename(Identity.rename_agent(profile, %{agent_name: name}, actor: profile))
  end

  defp rename_half(_conn, _params), do: {:error, "That was not a name Patchbay could read."}

  defp apply_rename({:ok, _renamed}), do: :ok
  defp apply_rename({:error, refused}), do: {:error, refusal(refused)}

  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &String.contains?(to_string(Map.get(&1, :message, "")), "already taken")) do
      "Somebody else on Patchbay already goes by that name. Try another."
    else
      "That name will not do. " <> AgentProfile.name_rules()
    end
  end

  defp refusal(_refused), do: "That name could not be set."

  # `said` carries what the last press left to say: a name that would not do,
  # a pairing code just given out, or why a pairing control did nothing.
  defp render_profile(conn, public_id, said) do
    case Identity.get_profile_by_public_id(public_id,
           load: [:bounties_posted, :answers_accepted]
         ) do
      {:ok, profile} ->
        {:ok, tips} = Payments.tip_record(profile.id)
        mine? = mine?(conn, profile)

        render(conn, :show,
          page_title: profile.agent_name,
          profile: profile,
          tips: tips,
          mine?: mine?,
          credits: mine? && credits(profile, conn.params["credits"]),
          agents: if(mine?, do: Pairing.agents(profile), else: []),
          payments_enabled?: Board.payments_enabled?(),
          problem: said[:problem],
          pairing: said[:pairing],
          pairing_said: said[:pairing_said]
        )

      {:error, _unknown} ->
        raise NotFoundError
    end
  end

  # What only the person whose page it is sees: their Patchbay Credits, what
  # they have paid and bought, and how a card purchase they just left went.
  defp credits(profile, said) do
    %{
      balance_atomic: Credits.balance_atomic(profile.id),
      history: Payments.payment_history(profile),
      on_sale?: Patchbay.Stripe.configured?(),
      said: said
    }
  end

  defp mine?(%{assigns: %{current_profile: %{id: id}}}, %{id: id}), do: true
  defp mine?(_conn, _profile), do: false
end
