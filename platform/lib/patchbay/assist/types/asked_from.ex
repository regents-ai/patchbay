defmodule Patchbay.Assist.Types.AskedFrom do
  @moduledoc """
  Where Jev was asked to choose a known fix: the free help for a site (its
  page or `get_site_help`), or the first step of a fix.
  """

  use Ash.Type.Enum, values: [:help, :fix]
end
