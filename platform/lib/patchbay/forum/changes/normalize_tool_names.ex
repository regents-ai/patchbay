defmodule Patchbay.Forum.Changes.NormalizeToolNames do
  @moduledoc """
  Tidies the `:tool_names` a post names: trimmed, deduplicated tool names, kept
  exactly as the site published them, at most five. Anything that cannot be a
  tool name refuses the whole post rather than silently disappearing from it.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Forum.ToolName

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tool_names) do
      names when is_list(names) -> normalize(changeset, names)
      _none -> changeset
    end
  end

  defp normalize(changeset, names) do
    normalized =
      names
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      not Enum.all?(normalized, &ToolName.valid?/1) ->
        refuse(changeset, "are the names the site published, like search_products")

      match?([_, _, _, _, _, _ | _], normalized) ->
        refuse(changeset, "names at most five tools")

      true ->
        Ash.Changeset.force_change_attribute(changeset, :tool_names, normalized)
    end
  end

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      InvalidAttribute.exception(field: :tool_names, message: message)
    )
  end
end
