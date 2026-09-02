defmodule Patchbay.Patchbay.Changes.DeriveVerificationResult do
  @moduledoc """
  Works out a verification row's verdict from the call it belongs to and the
  visible state that was observed.

  The verifier is the only thing that decides whether a call succeeded, so the
  verdict, the individual checks, the failure code and the expected state are
  written here rather than accepted from whoever is recording the row.
  """

  use Ash.Resource.Change

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.VerificationService

  @impl true
  def change(changeset, _opts, _context) do
    invocation = Domain.get_invocation!(Ash.Changeset.get_attribute(changeset, :invocation_id))
    observed_state = Ash.Changeset.get_attribute(changeset, :observed_state) || %{}
    result = VerificationService.derive_result(invocation, observed_state)

    changeset
    |> Ash.Changeset.force_change_attribute(:passed, result.passed)
    |> Ash.Changeset.force_change_attribute(:checks, result.checks)
    |> Ash.Changeset.force_change_attribute(:failure_code, result.failure_code)
    |> Ash.Changeset.force_change_attribute(:expected_state, result.expected_state)
    |> Ash.Changeset.force_change_attribute(:observed_state, result.observed_state)
  end
end
