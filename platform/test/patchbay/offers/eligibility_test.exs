defmodule Patchbay.Offers.EligibilityTest do
  @moduledoc """
  Whether a campaign may run (`Patchbay.Offers.Eligibility`). In a placement:
  where the campaign runs, Patchbay's word on its wallet, the placement's
  pools, Patchbay's review and the placement's policy must all agree, and
  anything missing counts against it. For a reader: the campaign's sealed
  targeting, with proof it requires and does not have counting against it.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Offers
  alias Patchbay.Offers.Eligibility

  @wallet "0x00000000000000000000000000000000000000a1"
  @other "0x00000000000000000000000000000000000000b2"
  @accepted %{rules: [%{wallet: @wallet, verdict: :accepted}], pools: %{}, site_kinds: %{}}

  defp campaign(attrs \\ %{}) do
    Map.merge(
      %{
        advertiser: @wallet,
        audience: :all,
        review: :approved,
        tags: [],
        kinds: [],
        requires: [],
        excluded_wallets: []
      },
      attrs
    )
  end

  defp placement(origin \\ "stripe.com", policy \\ Offers.policy_hash()),
    do: %{placement_id: 1, source_origin: origin, policy_hash: policy}

  defp pool(tags, members), do: %{tags: tags, members: Enum.map(members, &%{wallet: &1})}

  describe "in a placement" do
    test "a campaign for every site runs on any listed site, once accepted and approved" do
      assert :ok = Eligibility.check(campaign(), placement(), @accepted)
      assert {:error, :unknown_site} = Eligibility.check(campaign(), placement(nil), @accepted)
    end

    test "a campaign for some sites runs only on those it names" do
      sites = campaign(%{audience: :sites, sites: ["openai.com", "stripe.com"]})

      assert :ok = Eligibility.check(sites, placement("stripe.com"), @accepted)

      assert {:error, :not_on_site} =
               Eligibility.check(sites, placement("anthropic.com"), @accepted)
    end

    test "a campaign for one kind of site runs only on a site known to be that kind" do
      kind = campaign(%{audience: :group, group: :company})
      known = &%{@accepted | site_kinds: %{"stripe.com" => &1}}

      assert :ok = Eligibility.check(kind, placement(), known.(:company))
      assert {:error, :not_on_site} = Eligibility.check(kind, placement(), known.(:browser))
      assert {:error, :not_on_site} = Eligibility.check(kind, placement(), @accepted)
    end

    test "a wallet Patchbay has not accepted is refused, and a blocked one even when also accepted" do
      blocked = %{@accepted | rules: [%{wallet: @wallet, verdict: :blocked} | @accepted.rules]}
      elsewhere = %{@accepted | rules: [%{wallet: @other, verdict: :accepted}]}

      assert {:error, :not_accepted} =
               Eligibility.check(campaign(), placement(), %{@accepted | rules: []})

      assert {:error, :not_accepted} = Eligibility.check(campaign(), placement(), elsewhere)
      assert {:error, :blocked} = Eligibility.check(campaign(), placement(), blocked)

      # A pool naming the wallet does not lift the block.
      pooled = %{blocked | pools: %{1 => [pool([], [@wallet])]}}
      assert {:error, :blocked} = Eligibility.check(campaign(), placement(), pooled)
    end

    test "only a campaign Patchbay approved runs, and a pulled one never again" do
      assert {:error, :not_approved} =
               Eligibility.check(campaign(%{review: :waiting}), placement(), @accepted)

      assert {:error, :pulled} =
               Eligibility.check(campaign(%{review: :pulled}), placement(), @accepted)
    end

    test "a placement made under another policy admits no campaign" do
      other = placement("stripe.com", Offers.hash("another-policy"))
      assert {:error, :other_policy} = Eligibility.check(campaign(), other, @accepted)
    end
  end

  describe "pools" do
    test "with none chosen a placement shows from General, every accepted campaign" do
      assert :ok = Eligibility.check(campaign(%{tags: ["auth"]}), placement(), @accepted)
    end

    test "a chosen pool keeps campaigns about its tags, from its members" do
      payments = campaign(%{tags: ["payments", "checkout"]})
      untagged = campaign()
      chosen = &%{@accepted | pools: %{1 => &1}}

      # Tags only: any accepted member.
      assert :ok = Eligibility.check(payments, placement(), chosen.([pool(["payments"], [])]))

      assert {:error, :not_in_pool} =
               Eligibility.check(untagged, placement(), chosen.([pool(["payments"], [])]))

      # Members only: any campaign of theirs.
      assert :ok = Eligibility.check(untagged, placement(), chosen.([pool([], [@wallet])]))

      assert {:error, :not_in_pool} =
               Eligibility.check(untagged, placement(), chosen.([pool([], [@other])]))

      # Both, and in any one of the pools chosen.
      assert {:error, :not_in_pool} =
               Eligibility.check(payments, placement(), chosen.([pool(["payments"], [@other])]))

      assert :ok =
               Eligibility.check(
                 payments,
                 placement(),
                 chosen.([pool(["auth"], []), pool(["checkout"], [@wallet])])
               )

      # Pools chosen for another placement say nothing about this one.
      assert :ok =
               Eligibility.check(untagged, placement(), %{
                 @accepted
                 | pools: %{2 => [pool(["auth"], [])]}
               })
    end
  end

  describe "for a reader" do
    @anyone %{wallet: nil, evidence: []}
    @question %{tags: ["payments"], kind: :help_needed}

    test "a campaign with no targeting goes with any answer, to anyone" do
      assert :ok = Eligibility.qualifies(campaign(), %{tags: [], kind: nil}, @anyone)
    end

    test "topic tags and kinds of thread must match the question" do
      assert :ok =
               Eligibility.qualifies(campaign(%{tags: ["auth", "payments"]}), @question, @anyone)

      assert {:error, :not_for_task} =
               Eligibility.qualifies(campaign(%{tags: ["auth"]}), @question, @anyone)

      assert :ok = Eligibility.qualifies(campaign(%{kinds: [:help_needed]}), @question, @anyone)

      assert {:error, :not_for_task} =
               Eligibility.qualifies(campaign(%{kinds: [:feature_request]}), @question, @anyone)

      # A page with no question matches no targeting.
      assert {:error, :not_for_task} =
               Eligibility.qualifies(
                 campaign(%{kinds: [:help_needed]}),
                 %{tags: [], kind: nil},
                 @anyone
               )
    end

    test "proof the campaign requires and the reader lacks makes it ineligible" do
      paired = campaign(%{requires: [:paired]})

      assert {:error, :missing_evidence} = Eligibility.qualifies(paired, @question, @anyone)

      assert {:error, :missing_evidence} =
               Eligibility.qualifies(paired, @question, %{wallet: @other, evidence: []})

      assert :ok =
               Eligibility.qualifies(paired, @question, %{wallet: @other, evidence: [:paired]})
    end

    test "a wallet the campaign leaves out is never shown it; an unknown wallet is on no list" do
      excluding = campaign(%{excluded_wallets: [@other]})

      assert {:error, :excluded} =
               Eligibility.qualifies(excluding, @question, %{wallet: @other, evidence: [:paired]})

      assert :ok = Eligibility.qualifies(excluding, @question, %{wallet: @wallet, evidence: []})
      assert :ok = Eligibility.qualifies(excluding, @question, @anyone)
    end
  end
end
