defmodule Patchbay.Patchbay.Changes.SeedRoom do
  use Ash.Resource.Change

  alias Patchbay.Patchbay.Fixtures

  @impl true
  def change(changeset, _opts, _context) do
    Fixtures.room_attributes()
    |> Enum.reduce(changeset, fn {attribute, value}, changeset ->
      Ash.Changeset.change_attribute(changeset, attribute, value)
    end)
  end
end
