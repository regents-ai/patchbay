defmodule Patchbay.Forum.Changes.NormalizeOrigin do
  @moduledoc """
  Turns the `:origin` argument into the bare lowercase host stored on the site,
  so that idempotency by origin holds no matter which URL an agent reported.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Forum.Origin

  @impl true
  def change(changeset, _opts, _context) do
    case Origin.normalize(Ash.Changeset.get_argument(changeset, :origin)) do
      {:ok, origin} ->
        Ash.Changeset.force_change_attribute(changeset, :origin, origin)

      {:error, message} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: :origin, message: message)
        )
    end
  end
end
