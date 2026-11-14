defmodule Patchbay.Offers.EligibilityTest do
  @moduledoc """
  Whether a campaign may run in a placement (`Patchbay.Offers.Eligibility`):
  where the campaign runs, Patchbay's word on its wallet and the placement's
  policy must all agree, and anything missing counts against it.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Offers
  alias Patchbay.Offers.Eligibility

  @wallet "0x00000000000000000000000000000000000000a1"
  @accepted [%{wallet: @wallet, verdict: :accepted}]

  defp campaign(audience \\ %{audience: :all}), do: Map.merge(%{advertiser: @wallet}, audience)

  defp placement(origin \\ "stripe.com", policy \\ Offers.policy_hash()),
    do: %{source_origin: origin, policy_hash: policy}

  test "a campaign for every site runs on any listed site, once its wallet is accepted" do
    assert :ok = Eligibility.check(campaign(), placement(), @accepted, nil)
    assert {:error, :unknown_site} = Eligibility.check(campaign(), placement(nil), @accepted, nil)
  end

  test "a campaign for some sites runs only on those it names" do
    sites = campaign(%{audience: :sites, sites: ["openai.com", "stripe.com"]})

    assert :ok = Eligibility.check(sites, placement("stripe.com"), @accepted, nil)

    assert {:error, :not_on_site} =
             Eligibility.check(sites, placement("anthropic.com"), @accepted, nil)
  end

  test "a campaign for one kind of site runs only on a site known to be that kind" do
    kind = campaign(%{audience: :group, group: :company})

    assert :ok = Eligibility.check(kind, placement(), @accepted, :company)
    assert {:error, :not_on_site} = Eligibility.check(kind, placement(), @accepted, :browser)
    assert {:error, :not_on_site} = Eligibility.check(kind, placement(), @accepted, nil)
  end

  test "a wallet Patchbay has not accepted is refused, and a blocked one even when also accepted" do
    blocked = [%{wallet: @wallet, verdict: :blocked} | @accepted]
    elsewhere = [%{wallet: "0x00000000000000000000000000000000000000b2", verdict: :accepted}]

    assert {:error, :not_accepted} = Eligibility.check(campaign(), placement(), [], nil)
    assert {:error, :not_accepted} = Eligibility.check(campaign(), placement(), elsewhere, nil)
    assert {:error, :blocked} = Eligibility.check(campaign(), placement(), blocked, nil)
  end

  test "a placement made under another policy admits no campaign" do
    other = placement("stripe.com", Offers.hash("another-policy"))
    assert {:error, :other_policy} = Eligibility.check(campaign(), other, @accepted, nil)
  end
end
