defmodule PatchbayWeb.PersonAdminLive do
  @moduledoc """
  The private page where an admin reads one profile's status, suspends or
  reinstates it for a reason, and reads the record of both: each change with
  its time, its reason and the admin who made it, or "Console" for one made
  with Patchbay's console commands.

  The page runs the same two actions Patchbay's console runs
  (`Patchbay.Identity.suspend_profile/3`, `reinstate_profile/3`), as the
  signed-in admin, and reads the record as them too: the actions' policies
  decide, never this page. An admin's own page shows their status and no
  action, because the policy refuses a change to oneself.

  Only a moderator reaches the page (`PatchbayWeb.Moderators`); anyone else
  is answered as though it does not exist.
  """

  use PatchbayWeb, :live_view

  import PatchbayWeb.AdminLinks, only: [admin_links: 1]
  import PatchbayWeb.Forum.BoardHTML, only: [board_header: 1, moment: 1]

  alias Patchbay.Identity
  alias Patchbay.Identity.AgentProfile
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.Read

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    {:ok,
     socket
     |> assign(PatchbayWeb.PublicDocuments.page("/admin/people/:public_id"))
     |> assign(public_id: public_id, problem: nil, person: %Read{})
     |> reread()}
  end

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, reread(socket)}

  def handle_event("suspend", %{"reason" => reason}, socket),
    do: {:noreply, change(socket, &Identity.suspend_profile/3, reason)}

  def handle_event("reinstate", %{"reason" => reason}, socket),
    do: {:noreply, change(socket, &Identity.reinstate_profile/3, reason)}

  # The profile is read again for each press, so the action judges the row as
  # it is now, and the page shows whatever the press left.
  defp change(socket, action, reason) do
    result =
      with {:ok, profile} <- Identity.get_profile_by_public_id(socket.assigns.public_id),
           do: action.(profile, reason, actor: socket.assigns.current_profile)

    case result do
      {:ok, _profile} -> socket |> assign(problem: nil) |> reread()
      {:error, problem} -> socket |> assign(problem: words(problem)) |> reread()
    end
  end

  defp reread(socket) do
    %{public_id: public_id, current_profile: admin} = socket.assigns
    socket = Read.now(socket, :person, public_id, fn -> read_person(public_id, admin) end)

    if match?(%Read{error: %Ash.Error.Invalid{}}, socket.assigns.person),
      do: raise(NotFoundError),
      else: socket
  end

  defp read_person(public_id, admin) do
    with {:ok, profile} <- Identity.get_profile_by_public_id(public_id),
         {:ok, changes} <-
           Identity.status_changes(profile.id, actor: admin, load: [:moderator]) do
      {:ok, %{profile: profile, changes: Enum.reverse(changes)}}
    end
  end

  defp words(%Ash.Error.Invalid{errors: errors}), do: Enum.map_join(errors, " ", &refusal/1)
  defp words(%Ash.Error.Forbidden{}), do: "Only an admin can do that, and never to themself."
  defp words(_problem), do: "That could not be saved. Try again in a moment."

  defp refusal(%Ash.Error.Changes.Required{field: :reason}), do: "Give a reason."

  defp refusal(%Ash.Error.Changes.InvalidArgument{field: :reason, vars: vars}),
    do: "Keep the reason to #{vars[:max]} characters."

  defp refusal(%Ash.Error.Changes.InvalidAttribute{field: :status, message: said}),
    do: "This person #{said}."

  defp refusal(_error), do: "No profile has that id."

  @doc false
  def status_label(:active), do: "Active"
  def status_label(:suspended), do: "Suspended"

  @doc false
  def status_tone(:active), do: "is-good"
  def status_tone(:suspended), do: "is-bad"

  @doc false
  def change_label(:suspend), do: "Suspended"
  def change_label(:reinstate), do: "Reinstated"

  @doc false
  def kind_label(%{authentication_origin: :privy}), do: "Person"
  def kind_label(%{authentication_origin: :wallet}), do: "Wallet author"

  @doc false
  def name(profile), do: AgentProfile.own_name(profile)
end
