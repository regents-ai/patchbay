defmodule Patchbay.Forum.RoomMirrorTest do
  use Patchbay.DataCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Fixtures

  # Opening a room also publishes the generation-1 tool it offers.
  defp seeded_room!(slug) do
    room = Rooms.create_seeded_room!(slug)
    [v1] = Rooms.list_tool_revisions!(query: [filter: [room_id: room.id]])

    %{room: room, v1: v1}
  end

  # Publishing a new generation retires the one it replaces, which is why the
  # starting contract has to come from the fixture rather than from a room.
  defp improved!(room, v1, attrs) do
    if Map.get(attrs, :status, :desired) == :desired, do: Rooms.retire_tool_revision!(v1)

    room.id
    |> Fixtures.revision_attributes()
    |> Map.delete(:contract_sha256)
    |> Map.merge(%{
      generation: 2,
      name: "uplift_current_skill_v2",
      parent_revision_id: v1.id,
      status: :desired
    })
    |> Map.merge(attrs)
    |> Rooms.create_tool_revision!()
  end

  defp entries(site), do: Forum.list_tools_for_site!(site.id).results

  defp seeded_contract, do: Fixtures.revision_attributes(nil)

  test "puts this deployment on the board before any room exists" do
    site = RoomMirror.mirror!()

    assert site.origin == "patchbay.help"
    assert [only_site] = Forum.list_sites!().results
    assert only_site.id == site.id

    assert [entry] = entries(site)
    assert entry.name == "uplift_current_skill_v1"
    assert entry.contract_sha256 == seeded_contract().contract_sha256
    assert entry.title == seeded_contract().title
  end

  test "records an improved contract under the name the page advertised" do
    %{room: room, v1: v1} = seeded_room!("room-one")
    v2 = improved!(room, v1, %{description: "A clearer account of what this does."})

    site = RoomMirror.mirror!()

    assert [older, newer] = site |> entries() |> Enum.sort_by(& &1.last_seen_at, DateTime)

    assert Enum.map([older, newer], & &1.name) ==
             ["uplift_current_skill_v1", "uplift_current_skill_v2"]

    assert older.contract_sha256 == seeded_contract().contract_sha256
    assert newer.contract_sha256 == v2.contract_sha256
    assert newer.description == "A clearer account of what this does."
  end

  test "the same contract in many rooms collapses into one entry" do
    seeded_room!("room-one")
    seeded_room!("room-two")
    seeded_room!("room-three")

    site = RoomMirror.mirror!()

    assert [entry] = entries(site)
    assert entry.contract_sha256 == seeded_contract().contract_sha256
  end

  test "records every room's improved contract, each on its own entry" do
    %{room: first, v1: first_v1} = seeded_room!("room-one")
    %{room: second, v1: second_v1} = seeded_room!("room-two")

    improved!(first, first_v1, %{description: "Say what changed."})
    improved!(second, second_v1, %{description: "Keep the frontmatter."})

    site = RoomMirror.mirror!()

    assert length(entries(site)) == 3

    assert site
           |> entries()
           |> Enum.filter(&(&1.name == "uplift_current_skill_v2"))
           |> Enum.map(& &1.description)
           |> Enum.sort() == ["Keep the frontmatter.", "Say what changed."]
  end

  test "ignores a contract no room is offering" do
    %{room: room, v1: v1} = seeded_room!("room-one")
    improved!(room, v1, %{status: :candidate, description: "Never published."})

    site = RoomMirror.mirror!()

    assert [entry] = entries(site)
    assert entry.contract_sha256 == seeded_contract().contract_sha256
  end

  test "reads the host from the deployment's configured address" do
    System.put_env("PHX_HOST", "Board.Example.COM")
    on_exit(fn -> System.delete_env("PHX_HOST") end)

    assert RoomMirror.origin() == "board.example.com"
    assert RoomMirror.mirror!().origin == "board.example.com"
  end

  test "mirroring twice leaves one site and one entry per contract" do
    %{room: room, v1: v1} = seeded_room!("room-one")
    improved!(room, v1, %{description: "A clearer account of what this does."})

    site = RoomMirror.mirror!()
    assert RoomMirror.mirror!().id == site.id

    assert [_one] = Forum.list_sites!().results
    assert length(entries(site)) == 2
  end
end
