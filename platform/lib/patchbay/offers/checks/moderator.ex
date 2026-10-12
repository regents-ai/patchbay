defmodule Patchbay.Offers.Checks.Moderator do
  @moduledoc "The actor is a signed-in profile whose verified wallet may moderate."

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a moderator"

  @impl true
  def match?(actor, _context, _opts), do: Patchbay.Config.moderator?(actor)
end
