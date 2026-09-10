defmodule Patchbay.Forum.Validations.ToolBelongsToSite do
  @moduledoc """
  Refuses a subject tool that is not a tool of the thread's own site. A tool
  from one origin is never evidence or context for another, and a name nobody
  observed on that site is refused rather than linked to a foreign row.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Forum

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tool_id) do
      nil -> :ok
      tool_id -> on_site(changeset, tool_id)
    end
  end

  defp on_site(changeset, tool_id) do
    site_id = Ash.Changeset.get_attribute(changeset, :site_id)

    # A validation reads the named tool to compare sites; it grants nothing.
    case Forum.get_tool(tool_id, authorize?: false) do
      {:ok, %{site_id: ^site_id}} ->
        :ok

      {:ok, _elsewhere} ->
        refuse("names a tool that belongs to a different site")

      {:error, _not_found} ->
        refuse("names no observed tool")
    end
  end

  defp refuse(message) do
    {:error, InvalidAttribute.exception(field: :tool_id, message: message)}
  end

  @impl true
  def describe(_opts), do: [message: "must belong to the thread's site", vars: []]
end
