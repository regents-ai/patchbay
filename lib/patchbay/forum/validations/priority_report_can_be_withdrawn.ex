defmodule Patchbay.Forum.Validations.PriorityReportCanBeWithdrawn do
  @moduledoc """
  Refuses to send a report's escrowed money back to its asker when the money is
  not the asker's to take back: a report that was never paid for, one whose
  answer has already been accepted, or one whose money is already on its way
  somewhere.

  The check belongs here rather than in the endpoint because asking for the
  money back is what sends it. Every rule is read once, against the report as
  it is held under lock, so two asks arriving together cannot both get through.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  # The money is only the asker's to take back while the contract is still
  # holding it for them: credited and untouched, or left where it was by an
  # earlier ask the chain did not take.
  @withdrawable [:credited, :refund_failed]

  @impl true
  def validate(changeset, _opts, _context), do: withdrawable(changeset.data)

  @impl true
  def describe(_opts) do
    [message: "cannot be taken back", vars: []]
  end

  @spec withdrawable(struct()) :: :ok | {:error, Exception.t()}
  defp withdrawable(%{priority_amount_atomic: nil}) do
    refuse("This report has no money behind it, so there is nothing to take back.")
  end

  defp withdrawable(%{accepted_reply_id: accepted}) when is_binary(accepted) do
    refuse("You accepted an answer to this report, so the money has already been awarded.")
  end

  defp withdrawable(%{escrow_status: status}) when status in @withdrawable, do: :ok

  defp withdrawable(%{escrow_status: :refunding}) do
    refuse("Your money is already on its way back to you.")
  end

  defp withdrawable(%{escrow_status: :refunded}) do
    refuse("This money has already gone back to you.")
  end

  defp withdrawable(_report) do
    refuse("The money for this report is not being held on Base, so it cannot be sent back.")
  end

  @spec refuse(String.t()) :: {:error, Exception.t()}
  defp refuse(message) do
    {:error, InvalidAttribute.exception(field: :escrow_status, message: message)}
  end
end
