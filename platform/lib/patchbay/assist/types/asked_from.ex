defmodule Patchbay.Assist.Types.AskedFrom do
  @moduledoc """
  Where Jev was asked to choose a known fix: the first step of a fix, or, in
  decisions already recorded, the earlier free help for a site.
  """

  use Ash.Type.Enum, values: [:help, :fix]
end
