defmodule Patchbay.Assist.Types.ModelCallPurpose do
  @moduledoc """
  What a question to a model on OpenRouter was for: Jev choosing a known fix
  for the free help or for a fix's first step, choosing a site's tool,
  reading what a tool answered, or reading a priority report; or the
  drafting model writing a tool's arguments.
  """

  use Ash.Type.Enum,
    values: [
      :known_fix_for_help,
      :known_fix_for_fix,
      :choose_tool,
      :judge_answer,
      :read_report,
      :draft_arguments
    ]
end
