defmodule Patchbay.Patchbay.Validations.ObservedRegistryIsRoomToolset do
  @moduledoc """
  What a browser reports its tool registry holds has to be the toolset its room
  owns, at the revision the room is offering.

  A reconciliation reports the whole registry, so it has to hold the room's
  complete toolset. A toolchange reports the one registration that has just
  happened, so it may hold part of it. Either way every name is a tool Patchbay
  put there, and the digest reported for the room's own Skill tool is the digest
  Patchbay published for it.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.BrowserSession

  @sha256 ~r/\A[0-9a-f]{64}\z/

  @impl true
  def validate(changeset, _opts, _context) do
    names = Ash.Changeset.get_attribute(changeset, :observed_tool_names)
    contracts = Ash.Changeset.get_attribute(changeset, :observed_contracts)

    with :ok <- names_readable(names),
         :ok <- contracts_readable(contracts, names) do
      room_toolset(
        names,
        contracts,
        Ash.Changeset.get_argument(changeset, :observation),
        desired_revision(changeset)
      )
    end
  end

  @impl true
  def describe(_opts), do: "observed registry must be the room's own toolset"

  # One registration is reported once. Without this the tool count below could
  # be met by the same tool over and over.
  defp names_readable(names) do
    if length(names) == MapSet.size(MapSet.new(names)),
      do: :ok,
      else: error("observed_tool_names must not contain duplicates")
  end

  defp contracts_readable(contracts, names) do
    cond do
      Enum.any?(contracts, &unreadable_contract?/1) ->
        error("observed_contracts must map tool names to SHA-256 digests")

      MapSet.new(Map.keys(contracts)) != MapSet.new(names) ->
        error("observed contracts must exactly cover the observed tool names")

      true ->
        :ok
    end
  end

  defp unreadable_contract?({name, digest}) do
    not is_binary(name) or not is_binary(digest) or not Regex.match?(@sha256, digest)
  end

  defp room_toolset(names, contracts, observation, revision) do
    observed = MapSet.new(names)
    expected = MapSet.new([revision.name | BrowserSession.permanent_tool_names()])

    cond do
      not MapSet.subset?(observed, expected) ->
        error("observed registry contains a tool Patchbay does not own")

      observation == :reconciled and observed != expected ->
        error("reconciled registry must contain the complete desired Patchbay toolset")

      MapSet.member?(observed, revision.name) and
          Map.get(contracts, revision.name) != revision.contract_sha256 ->
        error("observed tool contract does not match the desired revision")

      true ->
        :ok
    end
  end

  # The tool the room is offering now, read with the room this session belongs
  # to. A Patchbay room is open to read, so this needs no actor.
  defp desired_revision(changeset) do
    changeset.data.room_id
    |> Domain.get_room_by_id!(load: [:desired_tool_revision])
    |> Map.fetch!(:desired_tool_revision)
  end

  defp error(message), do: {:error, InvalidChanges.exception(message: message)}
end
