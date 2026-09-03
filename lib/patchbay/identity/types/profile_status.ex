defmodule Patchbay.Identity.Types.ProfileStatus do
  use Ash.Type.Enum, values: [:active, :suspended]
end
