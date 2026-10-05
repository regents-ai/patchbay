defmodule Patchbay.Offers.CreativeTest do
  # Saved Offers: every wording is kept exactly as it will be shown, waits for
  # screening, and a blocked wording never comes back under another name.
  use Patchbay.DataCase, async: true

  alias Patchbay.Identity
  alias Patchbay.Offers

  require Ash.Query

  test "saving an Offer keeps its first wording, normalized, waiting for screening" do
    owner = person()

    assert {:ok, creative} =
             Offers.create_creative("Spring", "Cafe\u{0301} deals at https://example.com.",
               actor: owner
             )

    [version] = Ash.read!(Offers.CreativeVersion, actor: owner)
    assert version.creative_id == creative.id
    assert version.version == 1
    assert version.text == "Caf\u{E9} deals at https://example.com."
    assert version.code_points == 34
    assert version.urls == ["https://example.com"]

    [review] = Ash.read!(Offers.Review, actor: owner)
    assert {review.kind, review.decision} == {:safety, :pending}
    assert review.screen_requested_at
  end

  test "text that breaks a rule saves nothing" do
    owner = person()

    assert {:error, error} = Offers.create_creative("Two lines", "first\nsecond", actor: owner)
    assert Exception.message(error) =~ "must be a single line"
    assert Ash.read!(Offers.Creative, actor: owner) == []
  end

  test "wordings number up, and only the owner can add one" do
    owner = person()
    {:ok, creative} = Offers.create_creative("Plan", "One", actor: owner)

    assert {:ok, %{version: 2}} = Offers.save_creative_version(creative.id, "Two", actor: owner)

    assert {:error, error} =
             Offers.save_creative_version(creative.id, "Mine now", actor: person())

    assert Exception.message(error) =~ "is not one of your saved Offers"
  end

  test "a blocked wording cannot be saved again under another saved Offer" do
    owner = person()

    {:ok, _creative} =
      Offers.create_creative("First", "Free keys at https://bad.example", actor: owner)

    [version] = Ash.read!(Offers.CreativeVersion, actor: owner)

    version
    |> Ash.Changeset.for_update(:block, %{reason: "malicious link"})
    |> Ash.update!(authorize?: false)

    assert {:error, error} =
             Offers.create_creative("Second", "Free keys at https://bad.example", actor: owner)

    assert Exception.message(error) =~ "was blocked by a moderator"
  end

  defp person do
    Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:offers-#{Ecto.UUID.generate()}",
      wallet_address: "0x" <> String.duplicate("c", 40)
    })
  end
end
