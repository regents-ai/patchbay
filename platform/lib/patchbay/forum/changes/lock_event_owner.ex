defmodule Patchbay.Forum.Changes.LockEventOwner do
  @moduledoc """
  One subscription save per account at a time. Inside the action's
  transaction, the row of the account a subscription counts against (the
  actor's beneficiary profile) is locked before its share is counted again,
  so two subscribes racing for the same id refresh one row rather than
  colliding on its insert, and a burst of new ones cannot all count the same
  room and all get in. The lock ends with the transaction.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Identity.AgentProfile

  @impl true
  def change(changeset, _opts, %{actor: %{beneficiary_profile_id: profile_id}})
      when is_binary(profile_id) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # Only takes the lock; no profile is returned to anyone.
      AgentProfile
      |> Ash.Query.filter(id == ^profile_id)
      # Compatible with the foreign-key key-share locks other writes hold.
      |> Ash.Query.lock("FOR NO KEY UPDATE")
      |> Ash.read_one!(authorize?: false)

      changeset
    end)
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, "event authority required")
end
