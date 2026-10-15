defmodule Patchbay.Assist.Types.ModelCallPurpose do
  @moduledoc """
  What a question to a model on OpenRouter was for: Jev choosing a known fix
  for a fix's first step (or, in questions already recorded, for the earlier
  free help), choosing a site's tool,
  reading what a tool answered, reading a priority report, screening an
  Offer's safety or its relevance to a site, or checking a post before it is
  published; or the drafting model writing a tool's arguments.
  """

  use Ash.Type.Enum,
    values: [
      :known_fix_for_help,
      :known_fix_for_fix,
      :choose_tool,
      :judge_answer,
      :read_report,
      :screen_offer,
      :offer_relevance,
      :check_post,
      :draft_arguments
    ]
end
