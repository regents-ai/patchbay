defmodule Patchbay.Forum.Types.EntityType do
  @moduledoc """
  What kind of thing a directory entry is. Chrome is a browser, not a company.
  """

  use Ash.Type.Enum, values: [:company, :product, :browser, :platform, :website, :organization]
end
