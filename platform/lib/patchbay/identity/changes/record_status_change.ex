defmodule Patchbay.Identity.Changes.RecordStatusChange do
  @moduledoc """
  Writes the profile's `Patchbay.Identity.StatusChange` row for the suspension
  or reinstatement this action makes, with its reason, in the action's own
  transaction and as the same actor, so the change and its record are saved
  together or not at all. The row's own action admits only this call, and
  names the actor as the moderator who made the change.
  """

  use Ash.Resource.Change

  alias Patchbay.Identity.StatusChange

  # It only adds a hook, so the action's update stays one atomic statement.
  @impl Ash.Resource.Change
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, profile ->
      with {:ok, _row} <-
             StatusChange
             |> Ash.Changeset.for_create(
               :record,
               %{
                 profile_id: profile.id,
                 action: changeset.action.name,
                 reason: Ash.Changeset.get_argument(changeset, :reason)
               },
               actor: context.actor,
               context: %{profile_status_action?: true}
             )
             |> Ash.create(),
           do: {:ok, profile}
    end)
  end
end
