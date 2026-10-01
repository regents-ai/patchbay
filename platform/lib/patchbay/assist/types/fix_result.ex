defmodule Patchbay.Assist.Types.FixResult do
  @moduledoc "What an agent says came of a known fix Jev chose for it."

  use Ash.Type.Enum, values: [:worked, :did_not_work]
end
