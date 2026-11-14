defmodule Patchbay.Offers.CampaignTest do
  @moduledoc """
  A campaign (`Patchbay.Offers.Campaign`) is written once, by a signed-in
  person for one of their own wallets, under an id anyone can check against
  its manifest. Its owner reads it; anyone else reads it once a lease shows it.
  """

  use Patchbay.DataCase, async: true

  import PatchbayTest.OfferFixtures, only: [person!: 1, wallet: 0, campaign!: 1, campaign!: 2]

  alias Patchbay.Offers
  alias Patchbay.Offers.Campaign

  @offer %{
    title: "Acme payments",
    body: "Take card payments in one line of code.",
    link: "https://acme.example/agents",
    audience: :all
  }

  setup do
    %{owner: person!(wallet())}
  end

  test "a person writes a campaign for their own wallet, under the hash of its manifest", %{
    owner: owner
  } do
    campaign = campaign!(owner)

    assert campaign.agent_profile_id == owner.id
    assert campaign.advertiser == owner.wallet_address
    assert campaign.campaign_id == Offers.hash(Campaign.manifest(campaign))

    # The manifest names every field the offer was written with, and nothing else.
    assert %{"version" => 1, "advertiser" => advertiser, "audience" => "all", "sites" => []} =
             Jason.decode!(Campaign.manifest(campaign))

    assert advertiser == owner.wallet_address

    # The same offer again is the same campaign, refused; any change is a new one.
    assert {:error, %Ash.Error.Invalid{errors: [%{field: :campaign_id}]}} =
             write(owner, %{advertiser: owner.wallet_address})

    changed = campaign!(owner, %{title: "Acme payouts"})
    refute changed.campaign_id == campaign.campaign_id
  end

  test "only an active, signed-in person writes a campaign, and only for their own wallet", %{
    owner: owner
  } do
    assert {:error, %Ash.Error.Forbidden{}} = write(owner, %{advertiser: wallet()})

    assert {:error, %Ash.Error.Forbidden{}} =
             write(%{owner | status: :suspended}, %{advertiser: owner.wallet_address})

    # Signed out, there is no account for the campaign to belong to.
    assert {:error, %Ash.Error.Invalid{errors: [%{relationship: :agent_profile}]}} =
             write(nil, %{advertiser: owner.wallet_address})

    assert Ash.read!(Campaign, authorize?: false) == []
  end

  test "sites are kept as site addresses, sorted and once each", %{owner: owner} do
    campaign =
      campaign!(owner, %{
        audience: :sites,
        sites: ["https://www.Stripe.com/pricing", "openai.com", "stripe.com"],
        group: :company
      })

    assert campaign.sites == ["openai.com", "stripe.com"]
    assert campaign.group == nil

    for_all = campaign!(owner, %{audience: :all, sites: ["stripe.com"], group: :company})
    assert {for_all.sites, for_all.group} == {[], nil}

    for_kind = campaign!(owner, %{audience: :group, group: :company, sites: ["stripe.com"]})
    assert {for_kind.sites, for_kind.group} == {[], :company}
  end

  test "a campaign names the sites or the kind of site it runs on", %{owner: owner} do
    for {attrs, field} <- [
          {%{audience: :sites, sites: []}, :sites},
          {%{audience: :sites, sites: ["stripe.com", "localhost"]}, :sites},
          {%{audience: :group}, :group}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: ^field}]}} =
               write(owner, Map.put(attrs, :advertiser, owner.wallet_address))
    end
  end

  test "the owner reads their campaigns; anyone else only one a lease shows", %{owner: owner} do
    shown = campaign!(owner)
    unshown = campaign!(owner, %{title: "Acme payouts"})
    PatchbayTest.OfferFixtures.lease!(1, 0, shown)

    stranger = person!(wallet())
    ids = [shown.campaign_id, unshown.campaign_id]

    assert owner |> mine() |> MapSet.new() == MapSet.new([shown.id, unshown.id])
    assert mine(stranger) == []

    for reader <- [stranger, nil] do
      assert [%{id: id}] = Offers.campaigns_by_ids!(ids, actor: reader)
      assert id == shown.id
      assert {:ok, nil} = Offers.get_campaign(unshown.id, actor: reader, not_found_error?: false)
    end
  end

  test "targeting is sealed into the id only when set, so a campaign without it keeps its id", %{
    owner: owner
  } do
    plain = campaign!(owner)

    # Exactly the manifest a campaign had before campaigns could target.
    assert Campaign.manifest(plain) ==
             ~s({"version":1,"advertiser":"#{owner.wallet_address}","title":"Acme payments",) <>
               ~s("body":"Take card payments in one line of code.","link":"https://acme.example/agents",) <>
               ~s("audience":"all","sites":[],"group":null,"notes":""})

    left_out = wallet()
    "0x" <> hex = left_out

    targeted =
      campaign!(owner, %{
        tags: ["Payments", "auth", "payments"],
        kinds: [:help_needed],
        requires: [:paired],
        excluded_wallets: ["0x" <> String.upcase(hex)],
        daily_limit: 3
      })

    assert targeted.campaign_id == Offers.hash(Campaign.manifest(targeted))
    refute targeted.campaign_id == plain.campaign_id

    assert %{
             "targeting" => %{
               "tags" => ["auth", "payments"],
               "kinds" => ["help_needed"],
               "requires" => ["paired"],
               "excluded_wallets" => [^left_out],
               "daily_limit" => 3
             }
           } = Jason.decode!(Campaign.manifest(targeted))

    # Only the parts it sets.
    limited = campaign!(owner, %{daily_limit: 2})

    assert %{"targeting" => %{"daily_limit" => 2} = only} =
             Jason.decode!(Campaign.manifest(limited))

    assert map_size(only) == 1
  end

  test "targeting names topic tags, wallet addresses and a limit from 1 to 100", %{owner: owner} do
    for {attrs, field} <- [
          {%{tags: ["not a tag!"]}, :tags},
          {%{excluded_wallets: ["stripe.com"]}, :excluded_wallets},
          {%{daily_limit: 0}, :daily_limit},
          {%{daily_limit: 101}, :daily_limit}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: ^field} | _]}} =
               write(owner, Map.put(attrs, :advertiser, owner.wallet_address))
    end
  end

  defp write(actor, attrs), do: Offers.write_campaign(Map.merge(@offer, attrs), actor: actor)
  defp mine(actor), do: Enum.map(Offers.my_campaigns!(actor: actor), & &1.id)
end
