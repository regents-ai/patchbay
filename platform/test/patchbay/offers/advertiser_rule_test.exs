defmodule Patchbay.Offers.AdvertiserRuleTest do
  @moduledoc """
  Patchbay's word on advertiser wallets (`Patchbay.Offers.AdvertiserRule`):
  only a moderator sets or removes a rule; Patchbay's own jobs and its
  moderators read them, and nobody else.

  The moderator list is application-wide, so this file runs alone.
  """

  use Patchbay.DataCase, async: false

  import Patchbay.ModeratorFixtures, only: [moderator: 0]
  import PatchbayTest.OfferFixtures, only: [person!: 1, wallet: 0]

  alias Patchbay.Offers

  @system %{role: :system}

  test "only a moderator sets or removes a rule, and setting one twice keeps one" do
    person = person!(wallet())
    moderator = moderator()

    for actor <- [person, @system, nil] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Offers.set_advertiser_rule(person.wallet_address, :accepted, actor: actor)
    end

    rule = Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: moderator)
    Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: moderator)
    assert [%{id: id}] = Offers.list_advertiser_rules!(actor: moderator)
    assert id == rule.id

    for actor <- [person, @system] do
      assert {:error, %Ash.Error.Forbidden{}} = Offers.remove_advertiser_rule(rule, actor: actor)
    end

    assert :ok = Offers.remove_advertiser_rule(rule, actor: moderator)
    assert Offers.list_advertiser_rules!(actor: @system) == []
  end

  test "the rules are read by Patchbay's jobs and moderators only, a wallet's own holder included" do
    person = person!(wallet())
    Offers.set_advertiser_rule!(person.wallet_address, :accepted, actor: moderator())
    wallets = [person.wallet_address]

    assert [%{verdict: :accepted}] = Offers.advertiser_rules!(wallets, actor: @system)
    assert [%{verdict: :accepted}] = Offers.advertiser_rules!(wallets, actor: moderator())

    for actor <- [person, nil] do
      assert {:error, %Ash.Error.Forbidden{}} = Offers.advertiser_rules(wallets, actor: actor)
    end
  end
end
