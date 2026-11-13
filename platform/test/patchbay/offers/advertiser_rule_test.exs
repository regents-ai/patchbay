defmodule Patchbay.Offers.AdvertiserRuleTest do
  @moduledoc """
  Patchbay's word on advertiser wallets (`Patchbay.Offers.AdvertiserRule`):
  only Patchbay sets or removes a rule, and a signed-in person reads only the
  rules on their own wallets.
  """

  use Patchbay.DataCase, async: true

  import PatchbayTest.OfferFixtures, only: [person!: 1, wallet: 0]

  alias Patchbay.Offers

  @system %{role: :system}

  test "only Patchbay sets or removes a rule, and setting one twice keeps one" do
    person = person!(wallet())

    assert {:error, %Ash.Error.Forbidden{}} =
             Offers.set_advertiser_rule(person.wallet_address, :accepted, actor: person)

    assert {:error, %Ash.Error.Forbidden{}} =
             Offers.set_advertiser_rule(person.wallet_address, :accepted)

    rule = Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: @system)
    Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: @system)
    assert [%{id: id}] = Offers.list_advertiser_rules!(actor: @system)
    assert id == rule.id

    assert {:error, %Ash.Error.Forbidden{}} = Offers.remove_advertiser_rule(rule, actor: person)
    assert :ok = Offers.remove_advertiser_rule(rule, actor: @system)
    assert Offers.list_advertiser_rules!(actor: @system) == []
  end

  test "a person reads the rules on their own wallets, and no one else's; signed out, none" do
    person = person!(wallet())
    other = wallet()

    Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: @system)
    Offers.set_advertiser_rule!(other, :blocked, actor: @system)
    wallets = [person.wallet_address, other]

    assert [%{wallet: own, verdict: :accepted}] = Offers.advertiser_rules!(wallets, actor: person)
    assert own == person.wallet_address
    assert length(Offers.advertiser_rules!(wallets, actor: @system)) == 2
    assert {:error, %Ash.Error.Forbidden{}} = Offers.advertiser_rules(wallets)
  end
end
