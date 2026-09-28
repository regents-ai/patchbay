defmodule Patchbay.Forum.Changes.FillFromTool do
  @moduledoc """
  Fills a report's site and tool name from the observed tool it is about. A
  tool already belongs to exactly one site, so a report written against an
  observed contract can only ever be filed on that site, and it is found by
  that tool's name like any other post about the tool; the caller is never
  asked to name either.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tool_id) do
      nil ->
        changeset

      tool_id ->
        # The check reads a row the caller already named; it grants nothing.
        case Forum.get_tool(tool_id, authorize?: false) do
          {:ok, tool} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:site_id, tool.site_id)
            |> Ash.Changeset.force_change_attribute(:tool_names, [tool.name])

          {:error, _not_found} ->
            changeset
        end
    end
  end
end
