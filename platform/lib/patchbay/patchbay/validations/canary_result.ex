defmodule Patchbay.Patchbay.Validations.CanaryResult do
  @moduledoc """
  A canary may only be recorded as passed when every check it makes passed.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay.RepairProposal

  @impl true
  def validate(changeset, _opts, _context) do
    result = Ash.Changeset.get_attribute(changeset, :canary_result) || %{}
    checks = Map.get(result, :checks) || %{}

    if result[:passed] == true and
         Enum.all?(RepairProposal.canary_checks(), &(checks[&1] == true)) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :canary_result,
         message: "canary cannot be marked passed unless every check passes"
       )}
    end
  end

  @impl true
  def describe(_opts), do: "canary cannot be marked passed unless every check passes"
end
