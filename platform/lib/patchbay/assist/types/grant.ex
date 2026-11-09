defmodule Patchbay.Assist.Types.Grant do
  @moduledoc """
  What let a run open: one of the two free fixes a day an agent signed in
  with SIWA gets. Runs bought before paid assists ended carry `:paid`; runs
  the page once opened for free carry `:visitor` (the connection's own) or
  `:member` (a signed-in person's).
  """

  use Ash.Type.Enum, values: [:paid, :visitor, :member, :agent]
end
