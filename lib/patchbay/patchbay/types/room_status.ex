defmodule Patchbay.Patchbay.Types.RoomStatus do
  use Ash.Type.Enum,
    values: [
      :ready,
      :invoking,
      :failed,
      :diagnosing,
      :repair_ready,
      :awaiting_approval,
      :publishing,
      :repaired,
      :retrying,
      :verified,
      :resetting,
      :error
    ]
end
