defmodule Patchbay.Patchbay.Validations.CallEvidenceIsCurrent do
  @moduledoc """
  A call may only run against the tool the room offers right now, through a
  browser that belongs to the same room.

  The rule compares records the call only names, so it reads the room, the
  browser session and the revision rather than trusting the caller's copies.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Patchbay.Patchbay, as: Domain

  @room_fields [:id, :desired_tool_generation]
  @session_fields [:id, :room_id]
  @revision_fields [:id, :room_id, :status, :generation]

  @impl true
  def validate(changeset, _opts, _context) do
    room = load(changeset, :room_id, &Domain.get_room_by_id!/2, @room_fields)

    session =
      load(changeset, :browser_session_id, &Domain.get_browser_session!/2, @session_fields)

    revision = load(changeset, :tool_revision_id, &Domain.get_tool_revision!/2, @revision_fields)

    current(room, session, revision)
  end

  @impl true
  def describe(_opts), do: "invocation must name the room's current tool and browser"

  defp load(changeset, attribute, getter, fields) do
    getter.(Ash.Changeset.get_attribute(changeset, attribute), query: [select: fields])
  end

  defp current(room, session, revision) do
    cond do
      session.room_id != room.id ->
        stale(:browser_session_id, "browser session belongs to another room")

      revision.room_id != room.id ->
        stale(:tool_revision_id, "tool revision belongs to another room")

      revision.status != :desired ->
        stale(:tool_revision_id, "tool revision is not desired")

      revision.generation != room.desired_tool_generation ->
        stale(:tool_revision_id, "tool revision is stale")

      true ->
        :ok
    end
  end

  defp stale(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
