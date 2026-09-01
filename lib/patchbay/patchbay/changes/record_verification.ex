defmodule Patchbay.Patchbay.Changes.RecordVerification do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.{PostconditionVerifier, VerificationService}

  @impl true
  def change(changeset, _opts, _context) do
    invocation = changeset.data
    post_state = Ash.Changeset.get_attribute(changeset, :post_state) || %{}
    result = trusted_or_derived_result(changeset, invocation, post_state)

    changeset
    |> reject_failure_code_mismatch(result)
    |> apply_result(result)
  end

  defp trusted_or_derived_result(changeset, invocation, post_state) do
    case changeset.context[:trusted_verification_result] do
      result when is_map(result) ->
        if PostconditionVerifier.valid_result?(result) do
          result
        else
          VerificationService.derive_result(invocation, post_state)
        end

      _ ->
        VerificationService.derive_result(invocation, post_state)
    end
  end

  defp reject_failure_code_mismatch(changeset, %{failure_code: failure_code}) do
    case Ash.Changeset.fetch_change(changeset, :failure_code) do
      :error ->
        changeset

      {:ok, ^failure_code} ->
        changeset

      {:ok, _supplied_failure_code} ->
        Ash.Changeset.add_error(
          changeset,
          "failure code must match the PostconditionVerifier result"
        )
    end
  end

  defp apply_result(changeset, %{passed: true} = result) do
    if PostconditionVerifier.successful_result?(result) do
      changeset
      |> Ash.Changeset.change_attribute(:post_state, result.observed_state)
      |> Ash.Changeset.change_attribute(:failure_code, nil)
      |> Ash.Changeset.change_attribute(:effective_status, :verified_success)
      |> maybe_set_verified_at()
    else
      Ash.Changeset.add_error(
        changeset,
        "passed verification requires a complete successful PostconditionVerifier result"
      )
    end
  end

  defp apply_result(changeset, %{passed: false, failure_code: failure_code} = result) do
    changeset
    |> Ash.Changeset.change_attribute(:post_state, result.observed_state)
    |> Ash.Changeset.change_attribute(:failure_code, failure_code)
    |> Ash.Changeset.change_attribute(:effective_status, :verified_failure)
    |> maybe_set_verified_at()
  end

  defp maybe_set_verified_at(changeset) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :verified_at)) do
      Ash.Changeset.change_attribute(changeset, :verified_at, DateTime.utc_now())
    else
      changeset
    end
  end
end
