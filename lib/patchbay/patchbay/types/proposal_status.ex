defmodule Patchbay.Patchbay.Types.ProposalStatus do
  use Ash.Type.Enum,
    values: [
      :requested,
      :canary_failed,
      :ready_for_approval,
      :approved,
      :published,
      :rejected
    ]
end
