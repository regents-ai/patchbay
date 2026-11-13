defmodule PatchbayWeb.IncidentMD do
  @moduledoc "The incidents list as Markdown, for an agent to read."

  use PatchbayWeb, :md

  alias Patchbay.Forum.PostAddress

  import PatchbayWeb.IncidentHTML,
    only: [status_word: 1, incident_path: 1, day: 1, replies_label: 1]

  embed_templates("incident_md/*")
end
