defmodule Patchbay.Patchbay.Types.RevisionStatus do
  use Ash.Type.Enum,
    values: [
      :candidate,
      :canary_passed,
      :ready_for_approval,
      :approved,
      :desired,
      :retired,
      :rejected,
      :failed
    ]
end
