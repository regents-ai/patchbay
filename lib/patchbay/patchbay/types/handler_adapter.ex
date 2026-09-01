defmodule Patchbay.Patchbay.Types.HandlerAdapter do
  use Ash.Type.Enum,
    values: [
      :return_candidate_only,
      :apply_candidate_to_editor,
      :apply_candidate_and_show_diff,
      :reject_on_invalid_frontmatter,
      :return_structured_error
    ]
end
