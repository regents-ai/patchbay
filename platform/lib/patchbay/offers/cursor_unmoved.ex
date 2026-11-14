defmodule Patchbay.Offers.CursorUnmoved do
  @moduledoc """
  Refuses to move a cursor another pass or a person has moved or stopped since
  this pass read it. The check runs inside the `UPDATE`, so a pass holding an
  old copy writes nothing.
  """

  use Ash.Resource.Validation

  @impl true
  def atomic(changeset, _opts, _context) do
    from = Ash.Changeset.get_argument(changeset, :from)

    {:atomic, [:next_block, :rescan_from], expr(next_block != ^from or not is_nil(rescan_from)),
     expr(
       error(Ash.Error.Changes.StaleRecord, %{
         resource: "agent offer cursor",
         filter: %{next_block: ^from}
       })
     )}
  end
end
