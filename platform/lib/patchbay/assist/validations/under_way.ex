defmodule Patchbay.Assist.Validations.UnderWay do
  @moduledoc """
  A run is closed once: only a run Patchbay is in the middle of can be
  finished, so a worker that outlived a restart's sweep, or a second close
  of any kind, changes nothing.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(%{data: %{status: :running}}, _opts, _context), do: :ok

  def validate(_changeset, _opts, _context),
    do: {:error, InvalidAttribute.exception(field: :status, message: "is not under way")}
end
