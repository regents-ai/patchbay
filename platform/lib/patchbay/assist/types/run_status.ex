defmodule Patchbay.Assist.Types.RunStatus do
  @moduledoc """
  Where an assist stands, from opening to the answer. `:paid` is a run that
  is open and waiting to be started.
  """

  use Ash.Type.Enum, values: [:paid, :running, :finished, :assessment_pending, :failed]
end
