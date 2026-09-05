defmodule Patchbay.Patchbay.Validations.BrowserSessionCanApply do
  @moduledoc """
  A call that will change the room's visible editor may only come from a browser
  that is still connected and is still showing the exact tool the room offers.

  Calls whose handler only returns a candidate change nothing on the page, so
  the rule does not apply to them.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay, as: Domain

  @room_fields [:id, :desired_tool_generation]

  @session_fields [
    :id,
    :webmcp_supported,
    :disconnected_at,
    :desired_generation,
    :observed_generation,
    :observed_tool_names,
    :observed_contracts
  ]

  @revision_fields [:id, :handler_adapter, :name, :contract_sha256]

  @impl true
  def validate(changeset, _opts, _context) do
    revision =
      Domain.get_tool_revision!(Ash.Changeset.get_attribute(changeset, :tool_revision_id),
        query: [select: @revision_fields]
      )

    applies(changeset, revision)
  end

  @impl true
  def describe(_opts), do: "browser session must be able to apply the room's current tool"

  defp applies(_changeset, %{handler_adapter: adapter})
       when adapter != :apply_candidate_to_editor,
       do: :ok

  defp applies(changeset, revision) do
    room =
      Domain.get_room_by_id!(Ash.Changeset.get_attribute(changeset, :room_id),
        query: [select: @room_fields]
      )

    session =
      Domain.get_browser_session!(Ash.Changeset.get_attribute(changeset, :browser_session_id),
        query: [select: @session_fields]
      )

    can_apply(room, session, revision)
  end

  defp can_apply(room, session, revision) do
    cond do
      session.webmcp_supported != true ->
        refuse(:webmcp_supported, "browser session is not WebMCP capable")

      not is_nil(session.disconnected_at) ->
        refuse(:disconnected_at, "browser session is disconnected")

      session.desired_generation != room.desired_tool_generation or
          session.observed_generation != room.desired_tool_generation ->
        refuse(:observed_generation, "browser session is stale")

      revision.name not in session.observed_tool_names ->
        refuse(:observed_tool_names, "browser session has not observed the tool revision")

      Map.get(session.observed_contracts, revision.name) != revision.contract_sha256 ->
        refuse(:observed_contracts, "browser session has not observed the tool contract")

      true ->
        :ok
    end
  end

  defp refuse(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
