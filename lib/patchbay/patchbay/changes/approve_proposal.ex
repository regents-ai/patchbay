defmodule Patchbay.Patchbay.Changes.ApproveProposal do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    status = Ash.Changeset.get_data(changeset, :status)
    canary_result = Ash.Changeset.get_data(changeset, :canary_result) || %{}
    passed = Map.get(canary_result, "passed") || Map.get(canary_result, :passed)

    cond do
      status != :ready_for_approval ->
        Ash.Changeset.add_error(changeset, "proposal is not ready for approval")

      passed != true ->
        Ash.Changeset.add_error(changeset, "proposal canary has not passed")

      true ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :approved)
        |> Ash.Changeset.change_attribute(
          :approved_by,
          Ash.Changeset.get_argument(changeset, :approved_by)
        )
        |> Ash.Changeset.change_attribute(:approved_at, DateTime.utc_now())
    end
  end
end
