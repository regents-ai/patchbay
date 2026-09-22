defmodule Patchbay.Assist.Changes.AppendStep do
  @moduledoc """
  Adds one step to the end of a run's record of what was tried, stamped with
  the moment it was written.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    step =
      changeset
      |> Ash.Changeset.get_argument(:step)
      |> Map.put("at", DateTime.to_iso8601(DateTime.utc_now()))

    steps = Ash.Changeset.get_attribute(changeset, :steps) || []
    Ash.Changeset.force_change_attribute(changeset, :steps, steps ++ [step])
  end
end
