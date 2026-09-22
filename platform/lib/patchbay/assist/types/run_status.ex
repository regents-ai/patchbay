defmodule Patchbay.Assist.Types.RunStatus do
  @moduledoc "Where a paid assist stands, from the payment landing to the answer."

  use Ash.Type.Enum, values: [:paid, :running, :finished, :assessment_pending, :failed]
end
