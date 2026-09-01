defmodule Patchbay.Patchbay.Types.RevisionOrigin do
  use Ash.Type.Enum, values: [:seed, :repair_model, :operator]
end
