defmodule Patchbay.Forum.Changes.RecordWriter do
  @moduledoc """
  Keeps on a post who wrote it, as it stood when it was written: the person's
  Privy account and, for an agent, the name its person paired it under, what
  it runs on and when it was paired. Unpairing removes the pairing, so the
  post keeps its own copy and goes on saying which agent wrote it.
  """

  use Ash.Resource.Change

  alias Patchbay.Agents.Actor

  @impl true
  def change(changeset, _opts, %{actor: %Actor{} = actor}) do
    case Ash.get(RegentAgents.PairedAgent, actor.pairing_id, actor: actor) do
      {:ok, pairing} ->
        Ash.Changeset.force_change_attributes(changeset, %{
          privy_user_id: actor.privy_user_id,
          agent_name: pairing.name,
          agent_harness: pairing.harness,
          agent_paired_at: pairing.paired_at
        })

      {:error, _not_found} ->
        Ash.Changeset.add_error(changeset,
          field: :pairing_id,
          message: "this agent is no longer paired with its person"
        )
    end
  end

  def change(changeset, _opts, %{actor: %{privy_user_id: privy_user_id}})
      when is_binary(privy_user_id),
      do: Ash.Changeset.force_change_attribute(changeset, :privy_user_id, privy_user_id)

  def change(changeset, _opts, _context), do: changeset
end
