defmodule Patchbay.Offers.Validations.KnownOffer do
  @moduledoc """
  Keeps a report to an Offer Patchbay returned: the placement must exist and
  run the named wording, and a named response must have carried that
  placement. A link or wording on its own names nothing.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias Patchbay.Offers.DeliveryItem
  alias Patchbay.Offers.Placement

  @impl true
  def validate(changeset, _opts, _context) do
    placement_id = Ash.Changeset.get_attribute(changeset, :placement_id)
    version_id = Ash.Changeset.get_attribute(changeset, :version_id)
    delivery_id = Ash.Changeset.get_attribute(changeset, :delivery_id)

    cond do
      not runs?(placement_id, version_id) ->
        {:error,
         field: :placement_id, message: "is not an Offer Patchbay showed with that wording"}

      delivery_id && not carried?(delivery_id, placement_id) ->
        {:error, field: :delivery_id, message: "did not carry that Offer"}

      true ->
        :ok
    end
  end

  # Placements are public; these reads check a reference and grant nothing,
  # so they skip authorization deliberately.
  defp runs?(placement_id, version_id) do
    match?(
      {:ok, %{version_id: ^version_id}},
      Ash.get(Placement, placement_id, authorize?: false)
    )
  end

  # As above.
  defp carried?(delivery_id, placement_id) do
    DeliveryItem
    |> Ash.Query.filter(delivery_id == ^delivery_id and placement_id == ^placement_id)
    |> Ash.exists?(authorize?: false)
  end
end
