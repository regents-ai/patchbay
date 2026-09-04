defmodule Patchbay.Patchbay.RoomEntrance do
  @moduledoc """
  How a visitor reaches a repair room.

  `/webmcp/rooms/skill-uplift` is the shared preview. A personal room is
  created only after Privy sign-in, one per profile, at a stable slug.
  """

  alias Patchbay.Identity.AgentProfile
  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Room, RoomCapacity}

  @showcase_slug "skill-uplift"

  @doc "The published demo address. It is a preview, not somebody's room."
  @spec showcase_slug() :: String.t()
  def showcase_slug, do: @showcase_slug

  @doc "The room slug that belongs to this signed-in profile."
  @spec personal_slug(AgentProfile.t()) :: String.t()
  def personal_slug(%{public_id: public_id}) when is_binary(public_id), do: "p-" <> public_id

  @doc "The shared read-only preview, created on first visit."
  @spec ensure_showcase() :: {:ok, Room.t()} | {:error, :at_capacity}
  def ensure_showcase, do: ensure_room(@showcase_slug)

  @doc "The signed-in profile's own room, created the first time they sign in."
  @spec ensure_personal(AgentProfile.t()) :: {:ok, Room.t()} | {:error, :at_capacity}
  def ensure_personal(%{} = profile), do: ensure_room(personal_slug(profile))

  defp ensure_room(slug) do
    case Domain.get_room_by_slug!(slug, not_found_error?: false) do
      %Room{} = room -> {:ok, room}
      nil -> RoomCapacity.create_room(slug)
    end
  end
end
