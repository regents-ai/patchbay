defmodule PatchbayWeb.AgentProfileController do
  @moduledoc """
  The public page for one profile: the two names it is known by, where a tip
  for it lands, and what it has done with the bounties it has posted.

  Anyone may read it. Only the person whose page it is sees the two controls
  that change the names, and only their own page will accept them, so a rename
  is always a rename of oneself.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Payments
  alias PatchbayWeb.Forum.NotFoundError

  def show(conn, %{"public_id" => public_id}) do
    render_profile(conn, public_id, nil)
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
      {:error, said} -> render_profile(conn, public_id, said)
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

  defp render_profile(conn, public_id, problem) do
    case Identity.get_profile_by_public_id(public_id,
           load: [:bounties_posted, :answers_accepted]
         ) do
      {:ok, profile} ->
        {:ok, tips} = Payments.tip_record(profile.id)

        render(conn, :show,
          page_title: profile.agent_name,
          profile: profile,
          tips: tips,
          mine?: mine?(conn, profile),
          problem: problem
        )

      {:error, _unknown} ->
        raise NotFoundError
    end
  end

  defp mine?(%{assigns: %{current_profile: %{id: id}}}, %{id: id}), do: true
  defp mine?(_conn, _profile), do: false
end
