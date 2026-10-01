defmodule Patchbay.Assist.Types.Grant do
  @moduledoc """
  What let a run open: a settled payment, the one free fix a day every
  connection to the page gets, one of the two more a day a signed-in
  person gets, or one of the two a day an agent signed in with SIWA gets.
  """

  use Ash.Type.Enum, values: [:paid, :visitor, :member, :agent]
end
