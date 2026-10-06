defmodule Patchbay.Offers.Removal do
  @moduledoc """
  The work behind `Patchbay.Offers.ModerationAction`'s
  `:remove_placement`, inside its transaction.

  A removal names one placement and the slot generation it began, never
  "whatever is in slot 2". Under the slot's lock the slot is brought up to
  date first (`Patchbay.Offers.Advance`). If the placement is still the one
  showing, it ends with nothing returned: the time shown counts as used and
  the rest is forfeited. Every bid in the slot's open windows comes back in
  full, and the waiting next-period leader starts at once at its own bid if
  its wording may still show. If the placement had already ended, nothing
  is removed and the decision records that.

  The moderator's request key answers a repeat with the first decision.
  """

  require Ash.Query

  alias Patchbay.Offers.Advance
  alias Patchbay.Offers.ModerationAction
  alias Patchbay.Offers.Placement
  alias Patchbay.Offers.Terms

  @doc "Removes one placement for `moderator`, or answers with the decision already made."
  def remove(%{no_refund: false}, _moderator) do
    {:error,
     Ash.Error.Changes.InvalidArgument.exception(
       field: :no_refund,
       message: "confirm that the owner gets nothing back"
     )}
  end

  def remove(args, moderator) do
    # Part of the action that asked, whose policy already decided.
    with nil <- decided(moderator, args.idempotency_key),
         {:ok, placement} <- Ash.get(Placement, args.placement_id, authorize?: false) do
      slot = Advance.lock(placement.slot_id)

      case decided(moderator, args.idempotency_key) do
        nil ->
          now = Advance.now()
          slot |> Advance.advance(now) |> decide(placement, args, moderator, now)

        action ->
          {:ok, action}
      end
    else
      %ModerationAction{} = action -> {:ok, action}
      {:error, error} -> {:error, error}
    end
  end

  defp decide(slot, placement, args, moderator, now) do
    case slot.active_placement do
      %Placement{id: id, generation: generation} = showing
      when id == placement.id and generation == args.expected_generation ->
        split = Terms.removed(showing.amount_minor, showing.expires_at, now)
        Advance.finish(showing, :removed_for_policy, now, split)
        Advance.give_back_windows(slot, [:immediate, :next_period], :placement_removed, now)
        slot = Advance.promote(slot, now)

        record(placement, args, moderator, %{
          outcome: :removed,
          consumed_minor: split.consumed,
          forfeited_minor: split.forfeited,
          promoted_placement_id: slot.active_placement_id,
          policy_revision: slot.market.policy_revision
        })

      _ended_or_other ->
        record(placement, args, moderator, %{outcome: :already_ended})
    end
  end

  defp record(placement, args, moderator, outcome) do
    # Part of the action that asked, whose policy already decided.
    ModerationAction
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(outcome, %{
        kind: :remove_placement,
        reason: args.reason,
        idempotency_key: args.idempotency_key,
        placement_id: placement.id,
        version_id: placement.version_id,
        expected_generation: args.expected_generation
      }),
      actor: moderator,
      authorize?: false
    )
    |> Ash.create()
  end

  defp decided(moderator, key) do
    # Part of the action that asked, whose policy already decided.
    ModerationAction
    |> Ash.Query.filter(moderator_profile_id == ^moderator.id and idempotency_key == ^key)
    |> Ash.read_one!(authorize?: false)
  end
end
