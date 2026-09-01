defmodule Patchbay.Patchbay.Validations.VerificationResult do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Patchbay.VerificationService

  @impl true
  def validate(changeset, _opts, _context) do
    provided = %{
      passed: Ash.Changeset.get_attribute(changeset, :passed),
      checks: Ash.Changeset.get_attribute(changeset, :checks),
      failure_code: Ash.Changeset.get_attribute(changeset, :failure_code),
      expected_state: Ash.Changeset.get_attribute(changeset, :expected_state),
      observed_state: Ash.Changeset.get_attribute(changeset, :observed_state)
    }

    derived = derive_result(changeset, provided.observed_state)

    if result_matches?(provided, derived) do
      :ok
    else
      {:error,
       InvalidChanges.exception(
         message: "verification fields must match the PostconditionVerifier result"
       )}
    end
  end

  @impl true
  def describe(_opts), do: "verification fields must be derived from PostconditionVerifier"

  defp derive_result(changeset, observed_state) do
    with invocation_id when not is_nil(invocation_id) <-
           Ash.Changeset.get_attribute(changeset, :invocation_id),
         {:ok, invocation} <- fetch_invocation(invocation_id),
         true <- is_map(observed_state) do
      VerificationService.derive_result(invocation, observed_state)
    else
      _ -> nil
    end
  end

  defp fetch_invocation(invocation_id) do
    {:ok, Patchbay.Patchbay.get_invocation!(invocation_id)}
  rescue
    _ -> :error
  end

  defp result_matches?(_provided, nil), do: false

  defp result_matches?(provided, derived) do
    Enum.all?([:passed, :checks, :failure_code, :expected_state, :observed_state], fn key ->
      Map.get(provided, key) == Map.get(derived, key)
    end)
  end
end
