defmodule Patchbay.CreditsHelp.Checks.Admin do
  @moduledoc """
  Whether the actor is one of Patchbay's moderators, who read and answer every
  Credits help post. The check reads the wallet recorded on the signed-in
  profile, never an address a request sends.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a Patchbay moderator"

  @impl true
  def match?(actor, _context, _opts), do: Patchbay.Config.moderator?(actor)
end
