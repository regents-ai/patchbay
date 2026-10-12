defmodule Patchbay.Offers.Changes.DailyOfferLimit do
  @moduledoc """
  Allows five saved wordings per account per UTC day, including edits.

  The account row serializes saves across all its Offers. The day's count
  (`Patchbay.Offers.DailySave`) is read and raised while that lock is held,
  and the count, save, safety review and job commit together. A refused or
  rolled-back save consumes nothing, and deleting an Offer gives nothing
  back. Routine screening refreshes do not create a wording or consume this
  share.
  """

  use Ash.Resource.Change
  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Offers.DailySave

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case context.actor do
        %{id: id} -> check(changeset, id)
        _missing -> changeset
      end
    end)
  end

  defp check(changeset, owner_id) do
    # Internal reads only enforce the actor's quota; no profile is returned.
    AgentProfile
    |> Ash.Query.filter(id == ^owner_id)
    # Compatible with the foreign-key key-share lock a new Creative already
    # holds, while serializing quota checks without a lock-upgrade deadlock.
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read_one!(authorize?: false)

    now = DateTime.utc_now()
    day = DateTime.to_date(now)
    # Waiting for the lock may cross midnight. Count and stamp the wording
    # using the same instant after admission, rather than changeset creation.
    changeset = Ash.Changeset.force_change_attribute(changeset, :inserted_at, now)

    used =
      DailySave
      |> Ash.Query.filter(owner_profile_id == ^owner_id and day == ^day)
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil -> 0
        %{saves: saves} -> saves
      end

    if used < 5 do
      count(changeset, %{owner_profile_id: owner_id, day: day, saves: used + 1})
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(
          field: :text,
          message:
            "cannot be saved: five new or changed Offers per account per UTC day is the limit; try again after 00:00 UTC"
        )
      )
    end
  end

  # Raised with the save it counts; a save that fails after this rolls the
  # count back with it.
  defp count(changeset, attrs) do
    DailySave
    |> Ash.Changeset.for_create(:count, attrs, authorize?: false)
    |> Ash.create!()

    changeset
  end
end
