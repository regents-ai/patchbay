defmodule Patchbay.Forum.Changes.NormalizeTopicTags do
  @moduledoc """
  Tidies the `:topic_tags` a caller supplies: trimmed, lowercased, deduplicated
  tag-shaped words, at most a handful of them. Anything that cannot be a tag
  refuses the whole post rather than silently disappearing from it.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute

  @tag ~r/\A[a-z0-9][a-z0-9-]{0,38}[a-z0-9]\z|\A[a-z0-9]\z/

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :topic_tags) do
      nil -> changeset
      tags when is_list(tags) -> normalize(changeset, tags)
      _other -> refuse(changeset, "must be a list of short tags")
    end
  end

  defp normalize(changeset, tags) do
    if Enum.all?(tags, &is_binary/1) do
      normalized =
        tags
        |> Enum.map(&String.downcase(String.trim(&1)))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      cond do
        Enum.any?(normalized, &(not Regex.match?(@tag, &1))) ->
          refuse(changeset, "tags are short lowercase words or hyphenated phrases")

        match?([_, _, _, _, _, _ | _], normalized) ->
          refuse(changeset, "names at most five topics")

        true ->
          Ash.Changeset.force_change_attribute(changeset, :topic_tags, normalized)
      end
    else
      refuse(changeset, "must be a list of short tags")
    end
  end

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      InvalidAttribute.exception(field: :topic_tags, message: message)
    )
  end
end
