defmodule Patchbay.Offers.Changes.LogTurnDown do
  @moduledoc """
  Logs a turn-down to `Patchbay.Offers.TurnDown` in the same transaction as
  the decision, so the admin page's list of turned-down Offers is never
  missing one: a review written as `:deny`, or an admin's block of a
  wording, logged against the wording that was pressed.
  """

  use Ash.Resource.Change

  alias Patchbay.Offers.CreativeVersion
  alias Patchbay.Offers.OfferText
  alias Patchbay.Offers.Review
  alias Patchbay.Offers.TurnDown

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      case entry(changeset, record) do
        nil -> {:ok, record}
        attrs -> log(attrs, record)
      end
    end)
  end

  defp entry(_changeset, %Review{decision: :deny} = review) do
    review.version_id
    |> version()
    |> Map.merge(%{
      kind: review.kind,
      market_id: review.market_id,
      reason_codes: review.reason_codes,
      private_reason: review.private_reason,
      model: review.model
    })
  end

  defp entry(_changeset, %Review{}), do: nil

  defp entry(changeset, %OfferText{} = text) do
    changeset
    |> Ash.Changeset.get_argument(:version_id)
    |> version()
    |> Map.merge(%{kind: :blocked, private_reason: text.block_reason})
  end

  # The words and the Offer's name as they are now, kept with the entry.
  # Read inside the decision's own transaction, which already decided who
  # may make it.
  defp version(version_id) do
    version = Ash.get!(CreativeVersion, version_id, load: [:creative], authorize?: false)

    %{
      version_id: version.id,
      text: version.text,
      label: version.creative.label,
      owner_profile_id: version.creative.owner_profile_id
    }
  end

  # Written only here, with the turn-down it records; its action forbids
  # every caller, so it skips authorization deliberately.
  defp log(attrs, record) do
    TurnDown
    |> Ash.Changeset.for_create(:log, attrs, authorize?: false)
    |> Ash.create()
    |> case do
      {:ok, _entry} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end
end
