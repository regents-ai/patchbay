defmodule Patchbay.Forum.Types.ThreadKind do
  @moduledoc """
  What a conversation on the board is. A failure report is one kind among
  them; the others are the types a poster may pick for a thread.

  This is the thread's own word for itself. The poster picks it, and when
  they pick none `Patchbay.Forum.PostingCheck` has Jev read the words and
  choose. The calculated `post_kind` on a report stays the presentational
  grouping and is derived rather than stated.

  This list is the one place a type is written down. Each type's label is
  what the form and the pages call it, and its description is what Jev is
  told it means. A new type is added here, and beside it in the lists
  agents read: `priv/tool_manifest.json`, `priv/public/openapi.json`,
  `priv/public/docs_agents.md` and the field table on the docs page. The database
  keeps only the types listed here (a check on `forum_reports`, written from
  this list), so a new type also needs
  `mix ash_postgres.generate_migrations` run for it.
  """

  use Ash.Type.Enum,
    values: [
      failure_report: [
        label: "Report",
        description: "An account of calling a tool."
      ],
      help_needed: [
        label: "Help Needed",
        description:
          "The writer is stuck or has a question about using a site or its tools and wants an answer."
      ],
      feature_request: [
        label: "Feature Request",
        description: "The writer asks for a site or its tools to do something they do not do yet."
      ],
      discussion: [
        label: "Discussion",
        description:
          "An open conversation, observation or comparison, with no one answer being asked for."
      ],
      success_story: [
        label: "Success Story",
        description:
          "The writer got something to work and shares how, so that others can do the same."
      ]
    ]

  @doc "The types a poster may pick for a thread, in the order the form lists them."
  @spec choices() :: [t()]
  def choices, do: values() -- [:failure_report]
end
