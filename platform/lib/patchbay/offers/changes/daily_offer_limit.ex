defmodule Patchbay.Offers.Changes.DailyOfferLimit do
  @moduledoc """
  Allows five saved wordings per account per UTC day, including edits.

  The account row serializes saves across all its Offers. The count reads
  committed versions while that lock is held, and the save, safety review
  and job commit together. A refused or rolled-back save consumes nothing.
  Routine screening refreshes do not create a wording or consume this share.
  """

  use Ash.Resource.Change
  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Offers.CreativeVersion

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
    starts = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    # Waiting for the lock may cross midnight. Count and stamp the wording
    # using the same instant after admission, rather than changeset creation.
    changeset = Ash.Changeset.force_change_attribute(changeset, :inserted_at, now)

    used =
      CreativeVersion
      |> Ash.Query.filter(creative.owner_profile_id == ^owner_id and inserted_at >= ^starts)
      |> Ash.count!(authorize?: false)

    if used < 5 do
      changeset
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
end
