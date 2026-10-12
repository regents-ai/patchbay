defmodule Patchbay.Offers.Validations.NeverBid do
  @moduledoc """
  Keeps deletion to a saved Offer none of whose wordings was ever bid with.
  A bid made while the deletion runs is kept by the database instead: a
  wording with a bid cannot be deleted.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    creative_id = changeset.data.id

    # Only whether a bid exists leaves here.
    Patchbay.Offers.Bid
    |> Ash.Query.filter(version.creative_id == ^creative_id)
    |> Ash.exists?(authorize?: false)
    |> if(
      do: {:error, field: :id, message: "has bids, so it cannot be deleted"},
      else: :ok
    )
  end
end
