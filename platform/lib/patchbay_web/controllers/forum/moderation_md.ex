defmodule PatchbayWeb.Forum.ModerationMD do
  @moduledoc "The moderation queue as markdown, for the moderator who asked for it."

  use PatchbayWeb, :md

  import PatchbayWeb.Forum.ModerationHTML,
    only: [subject_label: 1, subject_path: 2, subject_text: 1]

  embed_templates("moderation_md/*")
end
