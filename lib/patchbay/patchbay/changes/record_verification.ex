defmodule Patchbay.Patchbay.Changes.RecordVerification do
  @moduledoc """
  Projects a call's durable verification onto the call itself.

  The verification row is the only verdict there is: the status, the failure
  code, the observed state and the moment of judgement are all read from it,
  never re-derived and never taken from the caller.
  """

  use Ash.Resource.Change

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.PostconditionVerifier

  @result_fields [:passed, :checks, :failure_code, :expected_state, :observed_state]

  @impl true
  def change(changeset, _opts, _context) do
    verification = Domain.get_invocation_verification!(changeset.data.id)

    apply_verdict(changeset, verification, Map.take(verification, @result_fields))
  end

  # A successful verdict carries no failure code, so the row's own value is
  # right for both outcomes.
  defp apply_verdict(changeset, verification, result) do
    cond do
      PostconditionVerifier.successful_result?(result) ->
        record(changeset, verification, :verified_success)

      PostconditionVerifier.valid_result?(result) ->
        record(changeset, verification, :verified_failure)

      true ->
        Ash.Changeset.add_error(changeset, "persisted verification result is invalid")
    end
  end

  defp record(changeset, verification, status) do
    changeset
    |> Ash.Changeset.change_attribute(:post_state, verification.observed_state)
    |> Ash.Changeset.change_attribute(:failure_code, verification.failure_code)
    |> Ash.Changeset.change_attribute(:effective_status, status)
    |> Ash.Changeset.change_attribute(:verified_at, verification.inserted_at)
  end
end
