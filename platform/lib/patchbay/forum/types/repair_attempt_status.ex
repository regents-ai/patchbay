defmodule Patchbay.Forum.Types.RepairAttemptStatus do
  use Ash.Type.Enum,
    values: [
      :running,
      :published,
      :not_reproduced,
      :refused,
      :errored
    ]
end
