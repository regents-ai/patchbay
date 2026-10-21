defmodule PatchbayWeb.IncidentMD do
  @moduledoc "The incidents list and one incident's page as Markdown, for an agent to read."

  use PatchbayWeb, :md

  import PatchbayWeb.Forum.BoardMD, only: [post_line: 1]

  import PatchbayWeb.IncidentHTML,
    only: [
      status_word: 1,
      share_path: 1,
      fixes_path: 1,
      incident_path: 1,
      day: 1,
      threads_label: 1
    ]

  embed_templates("incident_md/*")

  @doc "The fixes as list lines, each marked when its poster said a reply fixed it."
  def fix_lines([]), do: "_No fixes shared yet._"

  def fix_lines(fixes) do
    Enum.map_join(fixes, "\n", fn fix ->
      post_line(fix) <> if(fix.solved, do: " · solved", else: "")
    end)
  end
end
