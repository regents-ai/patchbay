defmodule Patchbay.Forum.Types.RepairAttemptStatus do
  use Ash.Type.Enum,
    values: [
      :queued,
      :running,
      :published,
      :not_reproduced,
      :refused,
      :errored
    ]
end
