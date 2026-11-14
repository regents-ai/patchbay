defmodule Patchbay.Offers.AdmissionTest do
  @moduledoc """
  Patchbay's admission of a purchase (`Patchbay.Offers.Admission`): closed
  while no publisher key is set; otherwise only for a signed-in person's own
  campaign, paid from its own wallet, in a slot the market has, when the
  campaign is eligible there, approved by Patchbay and not pulled. An admission is the publisher's signature over
  exactly the purchase. The market's own check of that signature is proven on
  anvil (`Patchbay.Offers.MarketLabTest`).

  The moderator list is application-wide, so this file runs alone.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import PatchbayTest.OfferFixtures

  alias Patchbay.{Forum, Offers}
  alias Patchbay.Offers.Admission
  alias PatchbayDev.OffersLab

  setup do
    offers_on!(publisher_private_key: OffersLab.publisher_key())

    person = person!(wallet())

    %{
      person: person,
      campaign: shown_campaign!(person),
      placement: placement!(1, "stripe.com")
    }
  end

  test "buying is closed while no publisher key is set", %{person: person, campaign: campaign} do
    offers_on!(publisher_private_key: nil)

    assert {:error, :closed} = Admission.check(person, campaign, 1, 0)
    assert {:error, :closed} = Admission.admit(person, campaign, 1, 0, 5_000_000, 0)
  end

  test "an admission is the publisher's signature over exactly the purchase, for ten minutes", %{
    person: person,
    campaign: campaign,
    placement: placement
  } do
    assert :ok = Admission.check(person, campaign, 1, 2)

    assert {:ok, %{purchase: purchase, buyer: buyer, permit: permit}} =
             Admission.admit(person, campaign, 1, 2, 5_500_000, 4)

    assert buyer == person.wallet_address

    assert %{placement_id: 1, slot: 2, amount: 5_500_000, expected_nonce: 4} = purchase
    assert purchase.campaign_id == campaign.campaign_id
    assert (purchase.deadline - System.os_time(:second)) in 595..600

    {:ok, digest} =
      purchase |> Admission.typed_data(placement.source_id, buyer) |> RegentChain.Typed.digest()

    assert signer(digest, permit) == OffersLab.accounts().publisher
  end

  test "Patchbay admits only a person's own campaign, from its own wallet", %{
    person: person,
    campaign: campaign
  } do
    stranger = person!(wallet())
    assert {:error, :not_your_campaign} = Admission.check(stranger, campaign, 1, 0)

    # The account no longer links the wallet the campaign pays from.
    unlinked = %{person | wallet_addresses: [wallet()]}
    assert {:error, :not_your_wallet} = Admission.check(unlinked, campaign, 1, 0)
  end

  test "Patchbay admits only a slot the market has", %{person: person, campaign: campaign} do
    assert {:error, :unknown_placement} = Admission.check(person, campaign, 2, 0)
    assert {:error, :unknown_slot} = Admission.check(person, campaign, 1, 3)
  end

  test "Patchbay admits only an accepted wallet that is not blocked", %{person: person} do
    unaccepted = person!(wallet())
    approved = campaign!(unaccepted)
    approve!(approved)
    assert {:error, :not_accepted} = Admission.check(unaccepted, approved, 1, 0)

    rule!(person.wallet_address, :blocked)

    assert {:error, :blocked} =
             Admission.check(person, campaign!(person, %{title: "Again"}), 1, 0)
  end

  test "Patchbay admits only a campaign it approved, and never one it pulled", %{
    person: person,
    campaign: campaign
  } do
    waiting = campaign!(person, %{title: "Acme payouts"})
    assert {:error, :not_approved} = Admission.check(person, waiting, 1, 0)

    assert :ok = Admission.check(person, campaign, 1, 0)
    Offers.pull_campaign!(campaign.campaign_id, %{reason: "Misleading"}, actor: moderator())
    assert {:error, :pulled} = Admission.check(person, campaign, 1, 0)
    assert {:error, :pulled} = Admission.admit(person, campaign, 1, 0, 5_000_000, 0)
  end

  test "a campaign for one kind of site is admitted where the site is listed as that kind", %{
    person: person
  } do
    websites = campaign!(person, %{audience: :group, group: :website})
    companies = campaign!(person, %{audience: :group, group: :company})
    Enum.each([websites, companies], &approve!/1)

    # Not yet listed, the site is of no known kind.
    assert {:error, :not_on_site} = Admission.check(person, websites, 1, 0)

    Forum.register_site!("stripe.com")
    assert :ok = Admission.check(person, websites, 1, 0)
    assert {:error, :not_on_site} = Admission.check(person, companies, 1, 0)
  end

  test "a placement made under another policy admits nothing", %{person: person, campaign: c} do
    placement!(2, "openai.com", %{policy_hash: Offers.hash("another-policy")})
    assert {:error, :other_policy} = Admission.check(person, c, 2, 0)
  end

  # The address that signed `digest`, from the 65-byte signature.
  defp signer(digest, "0x" <> permit) do
    <<r::binary-size(32), s::binary-size(32), v>> = Base.decode16!(permit, case: :lower)
    {:ok, <<4, public_key::binary-size(64)>>} = ExSecp256k1.recover(digest, r, s, v - 27)
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(public_key)
    "0x" <> Base.encode16(address, case: :lower)
  end
end
