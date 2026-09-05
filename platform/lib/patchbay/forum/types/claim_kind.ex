defmodule Patchbay.Forum.Types.ClaimKind do
  use Ash.Type.Enum, values: [:dns_txt, :well_known, :none]
end
