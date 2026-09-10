defmodule Patchbay.Forum.Changes.AssignSiteFromTool do
  @moduledoc """
  Fills a report's site from the tool it is about. A tool already belongs to
  exactly one site, so a report written against an observed contract can only
  ever be filed on that site; the caller is never asked to name it.
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
          {:ok, tool} -> Ash.Changeset.force_change_attribute(changeset, :site_id, tool.site_id)
          {:error, _not_found} -> changeset
        end
    end
  end
end
