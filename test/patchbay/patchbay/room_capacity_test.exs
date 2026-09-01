defmodule Patchbay.Patchbay.RoomCapacityTest do
  use Patchbay.DataCase, async: false

  alias Patchbay.Patchbay, as: Domain
  alias Patchbay.Patchbay.{Digest, RoomCapacity}

  require Ash.Query

  setup do
    previous = Application.get_env(:patchbay, :max_rooms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:patchbay, :max_rooms)
      else
        Application.put_env(:patchbay, :max_rooms, previous)
      end
    end)

    :ok
  end

  test "the reap removes a room nobody used and keeps one that holds evidence" do
    idle = Domain.create_seeded_room!("idle-room")
    used = Domain.create_seeded_room!("used-room")
    record_invocation!(used)

    age_room!(idle)
    age_room!(used)

    assert :ok = RoomCapacity.reap_unused_rooms()

    assert_raise Ash.Error.Invalid, fn -> Domain.get_room_by_slug!(idle.slug) end
    assert Domain.get_room_by_slug!(used.slug).id == used.id
  end

  test "the reap keeps an unused room that is still inside the idle window" do
    fresh = Domain.create_seeded_room!("fresh-room")

    assert :ok = RoomCapacity.reap_unused_rooms()

    assert Domain.get_room_by_slug!(fresh.slug).id == fresh.id
  end

  test "the reap keeps an aged unused room whose visitor was seen recently" do
    watched = Domain.create_seeded_room!("watched-room")
    age_room!(watched)

    Domain.register_browser_session!(%{
      room_id: watched.id,
      client_instance_id: Ash.UUID.generate(),
      user_agent_digest: Digest.sha256("test-agent"),
      webmcp_supported: true
    })

    assert :ok = RoomCapacity.reap_unused_rooms()

    assert Domain.get_room_by_slug!(watched.slug).id == watched.id
  end

  test "reaping an unused room takes its tool revision with it" do
    room = Domain.create_seeded_room!("swept-room")
    age_room!(room)

    RoomCapacity.reap_unused_rooms()

    assert Domain.list_tool_revisions!(query: [filter: [room_id: room.id]]) == []
  end

  test "creating a room refuses once the ceiling is reached" do
    Domain.create_seeded_room!("only-room")
    Application.put_env(:patchbay, :max_rooms, 1)

    assert {:error, :at_capacity} = RoomCapacity.create_room("would-be-room")
  end

  test "creating a room reaps an unused room rather than refusing" do
    stale = Domain.create_seeded_room!("stale-room")
    age_room!(stale)
    Application.put_env(:patchbay, :max_rooms, 1)

    assert {:ok, room} = RoomCapacity.create_room("wanted-room")
    assert room.slug == "wanted-room"
    assert_raise Ash.Error.Invalid, fn -> Domain.get_room_by_slug!(stale.slug) end
  end

  defp record_invocation!(room) do
    revision =
      Domain.list_tool_revisions!(query: [filter: [room_id: room.id], limit: 1]) |> List.first()

    session =
      Domain.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    Domain.record_invocation!(%{
      room_id: room.id,
      browser_session_id: session.id,
      tool_revision_id: revision.id,
      tool_contract_sha256: revision.contract_sha256,
      request_uuid: Ash.UUID.generate(),
      arguments: %{"instructions" => "make the greeting warmer"}
    })
  end

  # The idle window is measured from the room's own timestamp, so the cheapest
  # way to test the sweep is to age the row past it.
  defp age_room!(room) do
    past =
      DateTime.utc_now()
      |> DateTime.add(-(Patchbay.Config.room_idle_hours() + 1), :hour)

    Patchbay.Repo.query!("UPDATE rooms SET updated_at = $1 WHERE id = $2", [
      past,
      Ecto.UUID.dump!(room.id)
    ])
  end
end
