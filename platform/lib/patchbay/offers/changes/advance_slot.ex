defmodule Patchbay.Offers.Changes.AdvanceSlot do
  @moduledoc """
  The update behind the jobs that settle a window and end a placement: lock
  the record's slot, bring it up to date (`Patchbay.Offers.Advance`), and
  answer with the record as it now is. A job that runs twice, or after a
  bid already did the work, finds nothing due and changes nothing.
  """

  use Ash.Resource.ManualUpdate

  alias Patchbay.Offers.Advance

  @impl true
  def update(changeset, _opts, _context) do
    %resource{id: id, slot_id: slot_id} = changeset.data

    slot_id
    |> Advance.lock([])
    |> Advance.advance(Advance.now())

    # Read again inside the job's own action, which runs unauthorized.
    Ash.get(resource, id, authorize?: false)
  end
end
