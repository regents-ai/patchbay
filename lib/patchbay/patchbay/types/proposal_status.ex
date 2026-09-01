defmodule Patchbay.Patchbay.Types.ProposalStatus do
  use Ash.Type.Enum,
    values: [
      :requested,
      :generating,
      :proposed,
      :canary_running,
      :canary_failed,
      :ready_for_approval,
      :approved,
      :publishing,
      :published,
      :rejected,
      :failed
    ]
end
