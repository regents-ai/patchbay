defmodule Patchbay.Offers.Changes.RecordDecision do
  @moduledoc """
  Stamps a review's decision with the time, and gives an allow its freshness:
  it counts for `fresh_for_us` microseconds and then waits for screening
  again. Any other decision is never fresh.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    now = DateTime.utc_now()

    fresh_until =
      case Ash.Changeset.get_attribute(changeset, :decision) do
        :allow ->
          DateTime.add(now, Ash.Changeset.get_argument(changeset, :fresh_for_us), :microsecond)

        _other ->
          nil
      end

    Ash.Changeset.force_change_attributes(changeset, decided_at: now, fresh_until: fresh_until)
  end
end
