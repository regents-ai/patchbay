defmodule Patchbay.NearFunding.Changes.Quote do
  @moduledoc """
  Asks the 1Click service for a live quote before a funding is written, and
  keeps it: the NEAR price, the time estimate, the deposit address and when
  it closes. The call is made before the transaction opens; a refused or
  unanswered quote writes nothing.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      if changeset.valid?, do: ask(changeset), else: changeset
    end)
  end

  defp ask(changeset) do
    request = %{
      usdc_amount: Ash.Changeset.get_attribute(changeset, :usdc_amount),
      recipient: Ash.Changeset.get_attribute(changeset, :recipient),
      refund_to: Ash.Changeset.get_attribute(changeset, :refund_to),
      dry: false
    }

    case RegentNearIntents.quote(request) do
      {:ok, %{deposit_address: address, deadline: deadline} = quote}
      when is_binary(address) and not is_nil(deadline) ->
        Ash.Changeset.force_change_attributes(changeset, %{
          quote: quote.raw,
          near_amount: quote.amount_in_formatted,
          time_estimate_s: quote.time_estimate_s,
          deadline: deadline,
          deposit_address: address
        })

      {:ok, _no_address} ->
        Ash.Changeset.add_error(changeset, field: :quote, message: "came without an address")

      {:error, %{message: message}} ->
        Ash.Changeset.add_error(changeset, field: :quote, message: message)
    end
  end
end
