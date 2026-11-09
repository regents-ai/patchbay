defmodule Patchbay.Identity.Changes.QueueDisconnectApps do
  @moduledoc """
  Queues `Patchbay.Identity.DisconnectApps` for a person being suspended, in
  the suspension's own transaction: a suspension that is saved always has its
  job, and one that is not saved has none. Only a person signed in through
  Privy can connect apps, so a wallet author queues nothing.
  """

  use Ash.Resource.Change

  # It only adds a hook, so the action's update stays one atomic statement.
  @impl Ash.Resource.Change
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn
      _changeset, %{authentication_origin: :privy} = profile ->
        with {:ok, _job} <-
               Oban.insert(Patchbay.Identity.DisconnectApps.new(%{profile_id: profile.id})),
             do: {:ok, profile}

      _changeset, profile ->
        {:ok, profile}
    end)
  end
end
