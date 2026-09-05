defmodule PatchbayWeb.Forum.VersionDiffTest do
  use ExUnit.Case, async: true

  alias Patchbay.Forum.Tool
  alias PatchbayWeb.Forum.VersionDiff

  defp version(attrs), do: struct(Tool, Map.merge(%{title: nil, description: nil}, attrs))

  test "reads a title that was rewritten" do
    change =
      VersionDiff.between(
        version(%{title: "Start checkout"}),
        version(%{title: "Begin checkout"})
      )

    assert change.title_changed?
    assert change.title_before == "Start checkout"
    assert change.title_after == "Begin checkout"
    assert change.changed?
  end

  test "reads which sentences of a description were added and dropped" do
    change =
      VersionDiff.between(
        version(%{description: "Puts the cart through. It needs an address."}),
        version(%{description: "Puts the cart through. It needs a card."})
      )

    assert change.description_changed?

    assert change.sentences == [
             {:kept, "Puts the cart through."},
             {:removed, "It needs an address."},
             {:added, "It needs a card."}
           ]
  end

  test "a description that only grew keeps everything that was already there" do
    change =
      VersionDiff.between(
        version(%{description: "Puts the cart through."}),
        version(%{description: "Puts the cart through. It needs a card."})
      )

    assert change.sentences == [
             {:kept, "Puts the cart through."},
             {:added, "It needs a card."}
           ]
  end

  test "a version whose words did not move reports no change" do
    same = version(%{title: "Start checkout", description: "Puts the cart through."})
    change = VersionDiff.between(same, same)

    refute change.changed?
    refute change.title_changed?
    refute change.description_changed?
    assert change.sentences == [{:kept, "Puts the cart through."}]
  end

  test "a version with no words at all is compared without falling over" do
    change = VersionDiff.between(version(%{}), version(%{description: "Now it says something."}))

    assert change.sentences == [{:added, "Now it says something."}]
    assert change.changed?
  end

  test "pairs every version with the one before it, and leaves the oldest unpaired" do
    newest = version(%{contract_sha256: "c", description: "Third."})
    middle = version(%{contract_sha256: "b", description: "Second."})
    oldest = version(%{contract_sha256: "a", description: "First."})

    assert [{^newest, second_change}, {^middle, first_change}, {^oldest, nil}] =
             VersionDiff.version_changes([newest, middle, oldest])

    assert second_change.sentences == [{:removed, "Second."}, {:added, "Third."}]
    assert first_change.sentences == [{:removed, "First."}, {:added, "Second."}]
  end

  test "a single version has nothing behind it" do
    only = version(%{description: "Only."})

    assert [{^only, nil}] = VersionDiff.version_changes([only])
    assert VersionDiff.version_changes([]) == []
  end
end
