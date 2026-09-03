defmodule Patchbay.Forum.Validations.ReportCarriesABounty do
  @moduledoc """
  Refuses a refund request on a report nobody ever put money behind.

  This is the only thing the board decides about a refund. Whether the money
  can move, and whether the thirty days are up, is the escrow contract's to
  answer: a request Patchbay allowed and the chain refused is the ordinary
  case, and every press reaches the chain so that the chain can say so.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(%{data: %{priority_amount_atomic: nil}}, _opts, _context) do
    {:error,
     InvalidAttribute.exception(
       field: :priority_amount_atomic,
       message: "This report has no money behind it, so there is nothing to take back."
     )}
  end

  def validate(_changeset, _opts, _context), do: :ok

  @impl true
  def describe(_opts), do: [message: "carries no bounty", vars: []]
end
