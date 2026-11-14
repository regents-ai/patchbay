defmodule Patchbay.NearFunding.Refresh do
  @moduledoc """
  The `:refresh` action of `Patchbay.NearFunding.Funding`: reads where the
  swap behind its deposit address stands (`RegentNearIntents.status/1`) and
  keeps it. A read the service could not answer is an error, so the job
  tries again; the next minute's sweep picks the funding up after that.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.NearFunding

  @impl true
  def update(changeset, _opts, _context) do
    funding = changeset.data

    case RegentNearIntents.status(funding.deposit_address) do
      {:ok, status} ->
        NearFunding.record_funding_status(
          funding,
          Map.take(status, [:state, :origin_tx, :destination_tx])
        )

      {:error, %{message: message}} ->
        {:error, Ash.Error.Unknown.UnknownError.exception(error: message)}
    end
  end
end
