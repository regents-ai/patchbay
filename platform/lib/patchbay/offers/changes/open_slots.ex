defmodule Patchbay.Offers.Changes.OpenSlots do
  @moduledoc """
  Makes a market's three slots in the same transaction as the market. Each
  slot is an upsert on its market and number, so opening a market twice, or
  from two requests at once, still leaves exactly three.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, market ->
      # The market's own slots, made by the action that made the market.
      Enum.map(1..3, &%{market_id: market.id, number: &1})
      |> Ash.bulk_create(Patchbay.Offers.Slot, :open,
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true
      )
      |> case do
        %Ash.BulkResult{status: :success} -> {:ok, market}
        %Ash.BulkResult{errors: errors} -> {:error, errors}
      end
    end)
  end
end
