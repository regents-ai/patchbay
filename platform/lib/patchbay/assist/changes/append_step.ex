defmodule Patchbay.Assist.Changes.AppendStep do
  @moduledoc """
  Adds one step to the end of a run's record of what was tried, stamped with
  the moment it was written. The step goes after the steps of the run as the
  action last read it, which `:record_step` reads again under the row's lock
  just before.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    step =
      changeset
      |> Ash.Changeset.get_argument(:step)
      |> Map.put("at", DateTime.to_iso8601(DateTime.utc_now()))

    Ash.Changeset.before_action(changeset, fn changeset ->
      Ash.Changeset.force_change_attribute(changeset, :steps, changeset.data.steps ++ [step])
    end)
  end
end
