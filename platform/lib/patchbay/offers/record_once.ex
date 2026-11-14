defmodule Patchbay.Offers.RecordOnce do
  @moduledoc """
  Makes a row from one market event once. Two passes recording the same event
  take turns, so the second finds the first's row. Read again, an event must
  match the row already made, or the action is refused with
  `Patchbay.Offers.Diverged` and the reading stops at that block.
  """

  use Ash.Resource.Change

  @identity [:chain_id, :transaction_hash, :log_index]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&take_turn/1)
    |> Ash.Changeset.after_action(&same_as_recorded/2)
  end

  defp take_turn(changeset) do
    key =
      Jason.encode!([
        inspect(changeset.resource)
        | Enum.map(@identity, &Ash.Changeset.get_attribute(changeset, &1))
      ])

    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    changeset
  end

  # Only what the chain said is compared: the row's own id and the time it was
  # made are this site's.
  defp same_as_recorded(changeset, row) do
    if Enum.all?(
         changeset.action.accept,
         &same?(Map.fetch!(row, &1), Ash.Changeset.get_attribute(changeset, &1))
       ),
       do: {:ok, row},
       else: {:error, Patchbay.Offers.Diverged.exception(recorded_block: row.block_number)}
  end

  defp same?(%Decimal{} = recorded, %Decimal{} = read), do: Decimal.equal?(recorded, read)
  defp same?(recorded, read), do: recorded == read
end

defmodule Patchbay.Offers.Diverged do
  @moduledoc "An event read again from the chain does not match the row already made from it."

  use Splode.Error, fields: [:recorded_block], class: :invalid

  def message(_error), do: "conflicts with the record already made from the chain"
end
