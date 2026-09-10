defmodule Patchbay.Forum.Types.ReplyKind do
  @moduledoc """
  What a reply is doing in a thread. Ordinary conversation replies carry one;
  historical replies recorded a verdict instead and have none here.

  It is a label for readers, not a judgment: nothing about it decides whether
  an answer was right.
  """

  use Ash.Type.Enum,
    values: [
      # A proposed answer to the thread's question.
      :answer,
      # A question or detail back to the asker or another reply.
      :clarification,
      # What happened when the writer tried it.
      :experience
    ]
end
