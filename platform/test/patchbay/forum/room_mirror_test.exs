defmodule Patchbay.Forum.RoomMirrorTest do
  use Patchbay.DataCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Fixtures
  alias Patchbay.Patchbay.ToolPublisher

  # Opening a room also publishes the generation-1 tool it offers.
  defp seeded_room!(slug) do
    room = Rooms.create_seeded_room!(slug)
    [v1] = Rooms.list_tool_revisions!(query: [filter: [room_id: room.id]])

    %{room: room, v1: v1}
  end

  defp candidate!(room, v1, attrs) do
    room.id
    |> Fixtures.revision_attributes()
    |> Map.delete(:contract_sha256)
    |> Map.merge(%{
      generation: 2,
      name: "uplift_current_skill_v2",
      parent_revision_id: v1.id,
      status: :candidate
    })
    |> Map.merge(attrs)
    |> Rooms.create_tool_revision!()
  end

  defp published!(room, v1, attrs) do
    room |> candidate!(v1, attrs) |> ToolPublisher.publish!()
  end

  defp site!, do: Forum.get_site_by_origin!(RoomMirror.origin())

  defp entries, do: Forum.list_tools_for_site!(site!().id).results

  defp seeded_contract, do: Fixtures.revision_attributes(nil)

  test "opening a room puts this deployment and its tool on the board" do
    seeded_room!("room-one")

    assert [only_site] = Forum.list_sites!().results
    assert only_site.origin == "patchbay.help"

    assert [entry] = entries()
    assert entry.name == "uplift_current_skill_v1"
    assert entry.contract_sha256 == seeded_contract().contract_sha256
    assert entry.title == seeded_contract().title
  end

  test "publishing an improved contract records it under the name the page advertised" do
    %{room: room, v1: v1} = seeded_room!("room-one")
    v2 = published!(room, v1, %{description: "A clearer account of what this does."})

    assert [older, newer] = entries() |> Enum.sort_by(& &1.last_seen_at, DateTime)

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

    assert [_one] = Forum.list_sites!().results
    assert [entry] = entries()
    assert entry.contract_sha256 == seeded_contract().contract_sha256
  end

  test "records every room's improved contract, each on its own entry" do
    %{room: first, v1: first_v1} = seeded_room!("room-one")
    %{room: second, v1: second_v1} = seeded_room!("room-two")

    published!(first, first_v1, %{description: "Say what changed."})
    published!(second, second_v1, %{description: "Keep the frontmatter."})

    assert length(entries()) == 3

    assert entries()
           |> Enum.filter(&(&1.name == "uplift_current_skill_v2"))
           |> Enum.map(& &1.description)
           |> Enum.sort() == ["Keep the frontmatter.", "Say what changed."]
  end

  test "a contract no room is offering yet never reaches the board" do
    %{room: room, v1: v1} = seeded_room!("room-one")
    candidate!(room, v1, %{description: "Never published."})

    assert [entry] = entries()
    assert entry.contract_sha256 == seeded_contract().contract_sha256
  end

  test "reads the host from the deployment's configured address" do
    System.put_env("PHX_HOST", "Board.Example.COM")
    on_exit(fn -> System.delete_env("PHX_HOST") end)

    assert RoomMirror.origin() == "board.example.com"

    seeded_room!("room-one")

    assert [only_site] = Forum.list_sites!().results
    assert only_site.origin == "board.example.com"
  end

  test "recording the same contract twice leaves one site and one entry" do
    %{v1: v1} = seeded_room!("room-one")

    first = RoomMirror.record!(v1)
    assert RoomMirror.record!(v1).id == first.id

    assert [_one] = Forum.list_sites!().results
    assert [_entry] = entries()
  end
end
