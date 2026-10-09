defmodule Patchbay.Agents.OwnsPrincipal do
  @moduledoc "Subscriptions are private, bounded to the request's server-derived principal."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "owns the subscription principal"

  @impl true
  def match?(actor, %{changeset: changeset}, _opts) do
    principal = Ash.Changeset.get_attribute(changeset, :principal)
    owned?(actor, principal)
  end

  def match?(_, _, _), do: false

  defp owned?(%Patchbay.Agents.Actor{beneficiary_profile_id: id} = actor, principal) do
    principal == Patchbay.Forum.Principal.for_profile(id) and
      RegentAgents.Checks.Paired.match?(actor, %{}, repo: Patchbay.Repo)
  end

  defp owned?(%Patchbay.Identity.AgentProfile{id: id}, principal),
    do: principal == Patchbay.Forum.Principal.for_profile(id)

  defp owned?(%{forum_session_id: id}, principal) when is_binary(id),
    do: principal == Patchbay.Forum.Principal.for_session(id)

  defp owned?(_, _), do: false
end
