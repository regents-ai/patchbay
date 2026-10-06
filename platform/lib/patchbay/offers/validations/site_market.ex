defmodule Patchbay.Offers.Validations.SiteMarket do
  @moduledoc "Keeps relevance reviews to site markets; Global needs only the safety review."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # Reads the market's scope to check it; it grants nothing.
    case Patchbay.Offers.get_market(Ash.Changeset.get_attribute(changeset, :market_id),
           authorize?: false
         ) do
      {:ok, %{scope: :site}} -> :ok
      _global_or_missing -> {:error, field: :market_id, message: "must be a site's market"}
    end
  end
end
