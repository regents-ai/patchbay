defmodule Patchbay.Forum.Types.RepairAttemptPhase do
  @moduledoc """
  How far one repair attempt has got, in the order the worker moves through.

  An attempt's `status` says how it ended; its phase says how much of the work
  is behind it, so a room can show a repair happening rather than only its
  result. A report Patchbay declines to work is answered without any work being
  done on it, and never leaves `:queued`.
  """

  use Ash.Type.Enum,
    values: [
      :queued,
      :reading,
      :testing,
      :publishing,
      :done
    ]
end
