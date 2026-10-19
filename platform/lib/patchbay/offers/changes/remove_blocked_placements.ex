defmodule Patchbay.Offers.Changes.RemoveBlockedPlacements do
  @moduledoc """
  Ends every placement showing words a moderator just blocked, each exactly
  as a removal ends it (`Patchbay.Offers.ModerationAction`'s
  `:remove_placement`): nothing goes back to its owner, every bid waiting on
  its slot comes back in full, and the slot's next-period leader starts if
  it may. It runs in the block's own transaction, as the blocking
  moderator, so the words are never blocked while still holding a slot.

  Each removal's request key names the blocked words and the placement, so
  it is the same on every attempt and two removals never share one.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Offers
  alias Patchbay.Offers.Placement

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, text ->
      reason = Ash.Changeset.get_argument(changeset, :reason)

      text.text_sha256
      |> showing()
      |> Enum.reduce_while({:ok, text}, &remove(&1, &2, reason, context.actor))
    end)
  end

  defp showing(text_sha256) do
    # Part of the block, whose policy already decided.
    Placement
    |> Ash.Query.filter(status == :active and version.text_sha256 == ^text_sha256)
    |> Ash.read!(authorize?: false)
  end

  defp remove(placement, {:ok, text} = ok, reason, moderator) do
    Offers.remove_placement(
      %{
        placement_id: placement.id,
        expected_generation: placement.generation,
        reason: reason,
        no_refund: true,
        idempotency_key: "block:#{text.text_sha256}:#{placement.id}"
      },
      actor: moderator
    )
    |> case do
      {:ok, _action} -> {:cont, ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end
end
