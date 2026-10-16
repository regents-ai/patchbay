defmodule Patchbay.Assist.Types.Grant do
  @moduledoc """
  What let a run open: a settled payment, or one of the two free fixes a day
  an agent signed in with SIWA gets. Runs the page once opened for free carry
  `:visitor` (the connection's own) or `:member` (a signed-in person's).
  """

  use Ash.Type.Enum, values: [:paid, :visitor, :member, :agent]
end
