defmodule Patchbay.Forum.Types.JevKind do
  use Ash.Type.Enum, values: [:tool_defect, :usage_question, :setup_problem, :other]
end
