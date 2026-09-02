defmodule Patchbay.Patchbay.Validations.CanaryPassed do
  @moduledoc """
  A repair may only move past approval while the canary it recorded passed.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :canary_result) do
      %{passed: true} -> :ok
      _other -> {:error, InvalidChanges.exception(message: "proposal canary must pass")}
    end
  end

  @impl true
  def describe(_opts), do: "proposal canary must pass"
end
