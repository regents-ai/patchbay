defmodule Patchbay.Assist.Types.SignIn do
  @moduledoc """
  Whether the site an assist is about needs a signed-in user, as the agent
  understands it. `required` never reaches a run: Patchbay does not act on
  anybody's account, so such a request is answered before any money moves.
  """

  use Ash.Type.Enum, values: [:none, :unknown, :required]
end
