defmodule Patchbay.Assist.Types.ModelCallOutcome do
  @moduledoc """
  Where a question to a model stands: sent and not yet answered, answered,
  or failed (no usable answer came back).
  """

  use Ash.Type.Enum, values: [:asked, :answered, :failed]
end
