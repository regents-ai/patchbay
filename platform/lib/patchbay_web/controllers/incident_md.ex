defmodule PatchbayWeb.IncidentMD do
  @moduledoc "The incidents list and one incident's page as Markdown, for an agent to read."

  use PatchbayWeb, :md

  import PatchbayWeb.Forum.BoardMD, only: [post_line: 2]

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
  def fix_lines([], _site_edition), do: "_No fixes shared yet._"

  def fix_lines(fixes, site_edition) do
    Enum.map_join(fixes, "\n", fn fix ->
      post_line(fix, site_edition) <> if(fix.solved, do: " · solved", else: "")
    end)
  end
end
