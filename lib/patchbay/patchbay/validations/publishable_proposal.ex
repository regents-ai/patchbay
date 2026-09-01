defmodule Patchbay.Patchbay.Validations.PublishableProposal do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @impl true
  def validate(changeset, _opts, _context) do
    status = Ash.Changeset.get_attribute(changeset, :status)
    canary_result = Ash.Changeset.get_attribute(changeset, :canary_result)

    canary_passed =
      is_map(canary_result) and
        (Map.get(canary_result, "passed") || Map.get(canary_result, :passed)) == true

    cond do
      status != :approved ->
        {:error,
         InvalidChanges.exception(message: "proposal must be approved before publication")}

      not canary_passed ->
        {:error,
         InvalidChanges.exception(message: "proposal canary must pass before publication")}

      true ->
        :ok
    end
  end

  @impl true
  def describe(_opts), do: "proposal must be approved with a passed canary"
end
