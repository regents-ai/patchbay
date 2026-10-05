defmodule Patchbay.Forum.Changes.RecordDeliveryError do
  @moduledoc """
  Keeps why a subscription's delivery stopped: the callback's answer when it
  refused for good, or the last failure when Oban's attempts ran out. The
  reasons are atoms, status tuples and job errors; none holds a secret.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    error =
      case Ash.Changeset.get_argument(changeset, :error) do
        exception when is_exception(exception) -> Exception.message(exception)
        reason -> inspect(reason)
      end

    Ash.Changeset.force_change_attribute(changeset, :last_error, String.slice(error, 0, 500))
  end
end
