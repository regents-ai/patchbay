// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {IAgentOfferMarket} from "../src/IAgentOfferMarket.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {
    AgentOfferBase,
    ContractWallet,
    FreezableUSDC,
    HookUSDC,
    ITransferHook,
    RecordingStaking
} from "./AgentOfferTestKit.sol";

/// @title AgentOfferMarketTest
/// @notice What a market promises: placements whose terms never change; a purchase only with the
///         publisher's admission of exactly that purchase by exactly that buyer, at the slot's
///         current nonce, before its deadline, for at least the floor or the step over a live lease;
///         a replaced buyer refunded the unused share rounded down; earnings credited only when a
///         lease ends, split 90/10; termination refunding from its own moment, one slot at a time;
///         credit leaving only through its owner's claim; and nobody else's frozen wallet blocking
///         anything.
contract AgentOfferMarketTest is AgentOfferBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    uint256 internal placementId;

    function setUp() public {
        _deploy(new FreezableUSDC());
        placementId = _patchbayPlacement(market);
    }

    function _lease(uint16 slot) internal view returns (IAgentOfferMarket.Lease memory) {
        return market.getLease(placementId, slot);
    }

    function _now() internal view returns (uint64) {
        return SafeCast.toUint64(vm.getBlockTimestamp());
    }

    /// @dev A purchase made with a permit, expecting `err` from the market.
    function _expectBuyRevert(address buyer, IAgentOfferMarket.Purchase memory p, bytes memory permit, bytes memory err)
        internal
    {
        _fund(market, buyer, p.amountUSDC);
        vm.expectRevert(err);
        vm.prank(buyer);
        market.buy(p, permit);
    }

    // ---------------------------------------------------------------- set-up

    function test_initialize_runsOnceAndNeverOnTheImplementation() public {
        assertEq(address(market.usdc()), BASE_USDC);
        assertEq(market.publisher(), publisher);
        assertEq(market.payout(), payout);
        assertEq(address(market.staking()), address(staking));
        assertEq(market.feeBps(), FEE_BPS);

        IAgentOfferMarket.Init memory config = IAgentOfferMarket.Init({
            usdc: IERC20(BASE_USDC), publisher: stranger, payout: stranger, staking: staking, feeBps: 0
        });
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        market.initialize(config);

        AgentOfferMarket implementation = AgentOfferMarket(factory.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(config);
        assertEq(implementation.publisher(), address(0));
    }

    function _goodInit() internal view returns (IAgentOfferMarket.Init memory) {
        return IAgentOfferMarket.Init({
            usdc: IERC20(BASE_USDC), publisher: publisher, payout: payout, staking: staking, feeBps: 2_000
        });
    }

    function test_initialize_refusesABadConfiguration() public {
        address implementation = factory.implementation();
        IAgentOfferMarket.Init[6] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _goodInit();
        }
        bad[0].usdc = IERC20(address(0));
        bad[1].publisher = address(0);
        bad[2].payout = address(0);
        bad[3].staking = IRegentRevenueStaking(address(0));
        bad[4].feeBps = 2_001;

        for (uint256 i; i < bad.length; ++i) {
            AgentOfferMarket clone = AgentOfferMarket(Clones.clone(implementation));
            if (i == 5) bad[i].payout = address(clone);
            vm.expectRevert(IAgentOfferMarket.InvalidConfiguration.selector);
            clone.initialize(bad[i]);
        }

        AgentOfferMarket ok = AgentOfferMarket(Clones.clone(implementation));
        ok.initialize(_goodInit());
        assertEq(ok.feeBps(), 2_000);
    }

    // ---------------------------------------------------------------- placements

    function test_createPlacement_isPublisherOnlyAndNumbersFromOne() public {
        assertEq(placementId, 1);
        IAgentOfferMarket.Placement memory placement = market.getPlacement(placementId);
        assertEq(placement.sourceId, SOURCE);
        assertEq(placement.terms.capacity, CAPACITY);
        assertEq(placement.terms.durationSeconds, DURATION);
        assertEq(placement.terms.minBumpBps, BUMP_BPS);
        assertEq(placement.terms.floorUSDC, FLOOR);
        assertEq(placement.terms.policyHash, POLICY);
        assertEq(placement.terminatedAt, 0);

        IAgentOfferMarket.PlacementTerms memory terms = _terms(1, 1 days, 500, 1);
        vm.expectRevert(IAgentOfferMarket.NotPublisher.selector);
        vm.prank(payout);
        market.createPlacement(SOURCE, terms, "");

        vm.expectEmit(address(market));
        emit IAgentOfferMarket.PlacementCreated(2, SOURCE, 1, 1 days, 500, 1, POLICY, "ipfs://two");
        vm.prank(publisher);
        assertEq(market.createPlacement(SOURCE, terms, "ipfs://two"), 2);
        assertEq(market.placementCount(), 2);
    }

    function test_createPlacement_refusesTermsOutOfBounds() public {
        IAgentOfferMarket.PlacementTerms[7] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _terms(CAPACITY, DURATION, BUMP_BPS, FLOOR);
        }
        bad[0].capacity = 0;
        bad[1].durationSeconds = 0;
        bad[2].durationSeconds = 365 days + 1;
        bad[3].minBumpBps = 0;
        bad[4].minBumpBps = 10_001;
        bad[5].floorUSDC = 0;
        bad[6].policyHash = bytes32(0);

        vm.startPrank(publisher);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IAgentOfferMarket.InvalidTerms.selector);
            market.createPlacement(SOURCE, bad[i], "");
        }
        vm.expectRevert(IAgentOfferMarket.InvalidTerms.selector);
        market.createPlacement(bytes32(0), _terms(CAPACITY, DURATION, BUMP_BPS, FLOOR), "");

        // The edges themselves are accepted.
        uint256 edge = market.createPlacement(SOURCE, _terms(type(uint16).max, 365 days, 10_000, 1), "");
        vm.stopPrank();
        assertEq(market.getPlacement(edge).terms.capacity, type(uint16).max);

        // The last slot of the widest placement can be bought; the one past it cannot.
        _buy(market, alice, edge, type(uint16).max - 1, 1);
        assertEq(market.getLease(edge, type(uint16).max - 1).buyer, alice);
    }

    function test_unknownPlacementOrSlotIsRefusedEverywhere() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR);

        p.placementId = 99;
        _expectBuyRevert(alice, p, "", abi.encodeWithSelector(IAgentOfferMarket.UnknownPlacement.selector));
        vm.expectRevert(IAgentOfferMarket.UnknownPlacement.selector);
        market.settleExpired(99, 0);
        vm.expectRevert(IAgentOfferMarket.UnknownPlacement.selector);
        market.settleTerminated(0, 0);
        vm.expectRevert(IAgentOfferMarket.UnknownPlacement.selector);
        market.minimumPrice(99, 0);
        vm.expectRevert(IAgentOfferMarket.UnknownPlacement.selector);
        vm.prank(publisher);
        market.terminatePlacement(99);

        p.placementId = placementId;
        p.slot = CAPACITY;
        _expectBuyRevert(alice, p, "", abi.encodeWithSelector(IAgentOfferMarket.UnknownSlot.selector));
        vm.expectRevert(IAgentOfferMarket.UnknownSlot.selector);
        market.settleExpired(placementId, CAPACITY);
        vm.expectRevert(IAgentOfferMarket.UnknownSlot.selector);
        market.minimumPrice(placementId, CAPACITY);
    }

    // ---------------------------------------------------------------- buying an empty slot

    function test_buy_anEmptySlotAtTheFloorPullsThePaymentAndHoldsIt() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 1, FLOOR);
        bytes memory permit = _permit(market, p, alice);
        _fund(market, alice, FLOOR);

        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeasePurchased(
            placementId, 1, alice, _campaign(alice), FLOOR, _now(), _now() + DURATION, 1
        );
        vm.prank(alice);
        market.buy(p, permit);

        IAgentOfferMarket.Lease memory lease = _lease(1);
        assertEq(lease.buyer, alice);
        assertEq(lease.campaignId, _campaign(alice));
        assertEq(lease.paidUSDC, FLOOR);
        assertEq(lease.startsAt, _now());
        assertEq(lease.endsAt, _now() + DURATION);
        assertEq(lease.nonce, 1);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(market.totalLeaseDeposits(), FLOOR);
        assertEq(market.totalClaimable(), 0);
        assertEq(market.minimumPrice(placementId, 1), 5_500_000);
        assertEq(market.minimumPrice(placementId, 0), FLOOR);
        _assertBooks(market);
    }

    function test_buy_belowTheFloorIsRefusedAndAboveItIsKept() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR - 1);
        _expectBuyRevert(
            alice,
            p,
            _permit(market, p, alice),
            abi.encodeWithSelector(IAgentOfferMarket.AmountBelowMinimum.selector, FLOOR)
        );

        _buy(market, bob, placementId, 0, 9_000_000);
        assertEq(_lease(0).paidUSDC, 9_000_000);
        assertEq(market.minimumPrice(placementId, 0), 9_900_000);
    }

    // ---------------------------------------------------------------- buyouts

    function test_buyout_refundsTheUnusedShareAndCreditsTheEarnedShare() public {
        _buy(market, alice, placementId, 0, 9_000_000);
        skip(24 hours);

        IAgentOfferMarket.Purchase memory p = _purchase(market, bob, placementId, 0, 9_900_000);
        bytes memory permit = _permit(market, p, bob);
        _fund(market, bob, 9_900_000);

        // A third of the term used: 6 USDC back to Alice, 3 earned, of which 0.3 is the fee.
        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeaseSettled(
            placementId, 0, alice, 1, IAgentOfferMarket.SettleReason.BoughtOut, _now(), 6_000_000, 2_700_000, 300_000
        );
        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeasePurchased(
            placementId, 0, bob, _campaign(bob), 9_900_000, _now(), _now() + DURATION, 2
        );
        vm.prank(bob);
        market.buy(p, permit);

        assertEq(market.claimable(alice), 6_000_000);
        assertEq(market.claimable(payout), 2_700_000);
        assertEq(market.revenueOwed(), 300_000);
        assertEq(market.totalLeaseDeposits(), 9_900_000);

        // Bob's lease is a fresh full term; Alice's time is not inherited.
        IAgentOfferMarket.Lease memory lease = _lease(0);
        assertEq(lease.buyer, bob);
        assertEq(lease.startsAt, _now());
        assertEq(lease.endsAt, _now() + DURATION);
        assertEq(lease.nonce, 2);
        _assertBooks(market);
    }

    function test_buyout_minimumRoundsUp() public {
        _buy(market, alice, placementId, 0, 5_000_001);
        // 5_000_001 * 1.1 = 5_500_001.1, so the minimum is 5_500_002.
        assertEq(market.minimumPrice(placementId, 0), 5_500_002);

        IAgentOfferMarket.Purchase memory p = _purchase(market, bob, placementId, 0, 5_500_001);
        _expectBuyRevert(
            bob,
            p,
            _permit(market, p, bob),
            abi.encodeWithSelector(IAgentOfferMarket.AmountBelowMinimum.selector, 5_500_002)
        );

        _buy(market, bob, placementId, 0, 5_500_002);
        assertEq(_lease(0).buyer, bob);
        _assertBooks(market);
    }

    function test_buyout_ofOnesOwnLeaseWorksLikeAnyOther() public {
        _buy(market, alice, placementId, 2, 10_000_000);
        skip(36 hours);
        _buy(market, alice, placementId, 2, 11_000_000);

        // Half the term used: 5 back, 5 earned.
        assertEq(market.claimable(alice), 5_000_000);
        assertEq(market.claimable(payout), 4_500_000);
        assertEq(market.revenueOwed(), 500_000);
        IAgentOfferMarket.Lease memory lease = _lease(2);
        assertEq(lease.buyer, alice);
        assertEq(lease.paidUSDC, 11_000_000);
        assertEq(lease.endsAt, _now() + DURATION);
        assertEq(lease.nonce, 2);
        _assertBooks(market);
    }

    function test_buyout_inTheSameSecondRefundsEverything() public {
        _buy(market, alice, placementId, 0, FLOOR);
        _buy(market, bob, placementId, 0, 5_500_000);
        assertEq(market.claimable(alice), FLOOR);
        assertEq(market.claimable(payout), 0);
        assertEq(market.revenueOwed(), 0);
        _assertBooks(market);
    }

    function test_buy_oneSecondBeforeTheEndIsStillABuyout() public {
        _buy(market, alice, placementId, 0, 7_200_000);
        skip(DURATION - 1);
        assertEq(market.minimumPrice(placementId, 0), 7_920_000);

        _buy(market, bob, placementId, 0, 7_920_000);
        // One second of 259_200 left: 7_200_000 / 259_200 = 27.77..., rounded down to 27.
        assertEq(market.claimable(alice), 27);
        assertEq(market.claimable(payout) + market.revenueOwed(), 7_200_000 - 27);
        _assertBooks(market);
    }

    function test_buy_atTheExactSecondOfExpiryPaysTheFloorAndRefundsNothing() public {
        _buy(market, alice, placementId, 0, 7_200_000);
        skip(DURATION);
        assertEq(market.minimumPrice(placementId, 0), FLOOR);

        IAgentOfferMarket.Purchase memory p = _purchase(market, bob, placementId, 0, FLOOR);
        bytes memory permit = _permit(market, p, bob);
        _fund(market, bob, FLOOR);
        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeaseSettled(
            placementId, 0, alice, 1, IAgentOfferMarket.SettleReason.Expired, _now(), 0, 6_480_000, 720_000
        );
        vm.prank(bob);
        market.buy(p, permit);

        assertEq(market.claimable(alice), 0);
        assertEq(market.claimable(payout), 6_480_000);
        assertEq(market.revenueOwed(), 720_000);
        _assertBooks(market);
    }

    function test_buy_settlesAStaleSlotItself() public {
        _buy(market, alice, placementId, 0, FLOOR);
        skip(DURATION + 30 days);

        // Nobody settled the run-out lease; the purchase does it, charged only to its own end.
        IAgentOfferMarket.Purchase memory p = _purchase(market, bob, placementId, 0, FLOOR);
        bytes memory permit = _permit(market, p, bob);
        _fund(market, bob, FLOOR);
        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeaseSettled(
            placementId, 0, alice, 1, IAgentOfferMarket.SettleReason.Expired, START + DURATION, 0, 4_500_000, 500_000
        );
        vm.prank(bob);
        market.buy(p, permit);
        assertEq(_lease(0).nonce, 2);
        _assertBooks(market);
    }

    // ---------------------------------------------------------------- admission and ordering

    function test_buy_deadlineIsTheLastSecond() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR);
        p.deadline = _now() + 10;
        bytes memory permit = _permit(market, p, alice);

        skip(11);
        _expectBuyRevert(alice, p, permit, abi.encodeWithSelector(IAgentOfferMarket.PurchaseExpired.selector));

        rewind(1);
        vm.prank(alice);
        market.buy(p, permit);
        assertEq(_lease(0).buyer, alice);
    }

    function test_buy_refusesAZeroCampaign() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR);
        p.campaignId = bytes32(0);
        _expectBuyRevert(
            alice, p, _permit(market, p, alice), abi.encodeWithSelector(IAgentOfferMarket.ZeroCampaign.selector)
        );
    }

    function test_buy_raceForOneSlotLetsOnlyTheFirstLand() public {
        IAgentOfferMarket.Purchase memory pa = _purchase(market, alice, placementId, 0, FLOOR);
        IAgentOfferMarket.Purchase memory pb = _purchase(market, bob, placementId, 0, 6_000_000);
        bytes memory permitA = _permit(market, pa, alice);
        bytes memory permitB = _permit(market, pb, bob);
        _fund(market, alice, FLOOR);
        _fund(market, bob, 6_000_000);

        vm.prank(alice);
        market.buy(pa, permitA);

        // Bob signed for an empty slot at nonce 0; he does not become a buyout by accident.
        vm.expectRevert(abi.encodeWithSelector(IAgentOfferMarket.StaleLeaseNonce.selector, 1));
        vm.prank(bob);
        market.buy(pb, permitB);
        assertEq(usdc.balanceOf(bob), 6_000_000);
        assertEq(_lease(0).buyer, alice);
    }

    function test_permit_replayedAfterTheNonceMovedIsRefused() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR);
        bytes memory permit = _permit(market, p, alice);
        _fund(market, alice, 2 * uint256(FLOOR));
        vm.startPrank(alice);
        market.buy(p, permit);

        // The same purchase and permit again, now and after the lease has been settled.
        vm.expectRevert(abi.encodeWithSelector(IAgentOfferMarket.StaleLeaseNonce.selector, 1));
        market.buy(p, permit);
        vm.stopPrank();

        skip(DURATION);
        market.settleExpired(placementId, 0);
        assertEq(_lease(0).nonce, 1);
        p.deadline = _now() + 1;
        vm.expectRevert(abi.encodeWithSelector(IAgentOfferMarket.StaleLeaseNonce.selector, 1));
        vm.prank(alice);
        market.buy(p, permit);
    }

    function test_permit_coversExactlyOnePurchaseByOneBuyer() public {
        vm.prank(publisher);
        uint256 other = market.createPlacement(
            SOURCE, IAgentOfferMarket.PlacementTerms(CAPACITY, DURATION, BUMP_BPS, FLOOR, keccak256("policy-v2")), ""
        );

        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, 6_000_000);
        bytes memory permit = _permit(market, p, alice);
        bytes memory invalid = abi.encodeWithSelector(IAgentOfferMarket.InvalidPermit.selector);
        IAgentOfferMarket.Purchase memory changed;

        // Another buyer presenting Alice's admission. (Each changed purchase below is built afresh,
        // differing from `p` in one field only.)
        _expectBuyRevert(bob, p, permit, invalid);

        changed = _purchase(market, alice, placementId, 1, 6_000_000);
        _expectBuyRevert(alice, changed, permit, invalid);

        // Another placement, whose policy differs.
        changed = _purchase(market, alice, other, 0, 6_000_000);
        _expectBuyRevert(alice, changed, permit, invalid);

        changed = _purchase(market, alice, placementId, 0, 7_000_000);
        _expectBuyRevert(alice, changed, permit, invalid);

        changed = _purchase(market, alice, placementId, 0, 6_000_000);
        changed.campaignId = keccak256("another campaign");
        _expectBuyRevert(alice, changed, permit, invalid);

        changed = _purchase(market, alice, placementId, 0, 6_000_000);
        changed.deadline = p.deadline + 1;
        _expectBuyRevert(alice, changed, permit, invalid);

        // Signed for nonce 1 while the slot is at nonce 0.
        changed = _purchase(market, alice, placementId, 0, 6_000_000);
        changed.expectedLeaseNonce = 1;
        bytes memory forNonceOne = _permit(market, changed, alice);
        _expectBuyRevert(alice, p, forNonceOne, invalid);

        // Signed by a key that is not the publisher's, and a permit that is not a signature.
        _expectBuyRevert(alice, p, _sign(uint256(keccak256("not the publisher")), _digest(market, p, alice)), invalid);
        _expectBuyRevert(alice, p, hex"1234", invalid);
        _expectBuyRevert(alice, p, "", invalid);

        // The real thing still works.
        vm.prank(alice);
        market.buy(p, permit);
        assertEq(_lease(0).buyer, alice);
    }

    function test_permit_isTiedToTheChain() public {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR);
        bytes memory permit = _permit(market, p, alice);
        vm.chainId(1);
        _expectBuyRevert(alice, p, permit, abi.encodeWithSelector(IAgentOfferMarket.InvalidPermit.selector));
    }

    function test_eligibilityDigest_isStandardEip712OverThisClone() public view {
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 2, FLOOR);
        assertEq(market.eligibilityDigest(p, alice), _digest(market, p, alice));
        assertEq(market.ELIGIBILITY_TYPEHASH(), PERMIT_TYPEHASH);

        (, string memory name, string memory version, uint256 chainId, address verifying,,) = market.eip712Domain();
        assertEq(name, "AgentOfferMarket");
        assertEq(version, "1");
        assertEq(chainId, 8453);
        assertEq(verifying, address(market));
    }

    function test_permit_fromAContractWalletPublisherUsesErc1271() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("safe-owner");
        ContractWallet wallet = new ContractWallet(owner);
        vm.prank(admin);
        factory.setPublisherAllowed(address(wallet), true);
        vm.prank(address(wallet));
        AgentOfferMarket walletMarket = AgentOfferMarket(factory.createMarket(payout));
        uint256 id = _patchbayPlacement(walletMarket);

        IAgentOfferMarket.Purchase memory p = _purchase(walletMarket, alice, id, 0, FLOOR);
        bytes memory permit = _sign(ownerKey, _digest(walletMarket, p, alice));
        _fund(walletMarket, alice, FLOOR);
        vm.prank(alice);
        walletMarket.buy(p, permit);
        assertEq(walletMarket.getLease(id, 0).buyer, alice);

        // A wallet that stops approving stops admitting, and the publisher's own key is no wallet.
        wallet.revoke();
        p = _purchase(walletMarket, bob, id, 1, FLOOR);
        permit = _sign(ownerKey, _digest(walletMarket, p, bob));
        _fund(walletMarket, bob, FLOOR);
        vm.expectRevert(IAgentOfferMarket.InvalidPermit.selector);
        vm.prank(bob);
        walletMarket.buy(p, permit);
    }

    // ---------------------------------------------------------------- expiry

    function test_settleExpired_creditsEverythingOnceAndAnyoneMayCall() public {
        _buy(market, alice, placementId, 0, 6_000_000);
        skip(DURATION);

        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeaseSettled(
            placementId, 0, alice, 1, IAgentOfferMarket.SettleReason.Expired, _now(), 0, 5_400_000, 600_000
        );
        vm.prank(stranger);
        market.settleExpired(placementId, 0);

        IAgentOfferMarket.Lease memory lease = _lease(0);
        assertEq(lease.buyer, address(0));
        assertEq(lease.paidUSDC, 0);
        assertEq(lease.endsAt, 0);
        assertEq(lease.nonce, 1);
        assertEq(market.claimable(payout), 5_400_000);
        assertEq(market.revenueOwed(), 600_000);
        assertEq(market.minimumPrice(placementId, 0), FLOOR);

        // Settling again, or settling a slot never sold, changes nothing and emits nothing.
        vm.recordLogs();
        market.settleExpired(placementId, 0);
        market.settleExpired(placementId, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(market.claimable(payout), 5_400_000);
        assertEq(market.revenueOwed(), 600_000);
        _assertBooks(market);
    }

    function test_settleExpired_refusesALiveLeaseAndATerminatedPlacement() public {
        _buy(market, alice, placementId, 0, FLOOR);
        skip(DURATION - 1);
        vm.expectRevert(IAgentOfferMarket.LeaseLive.selector);
        market.settleExpired(placementId, 0);

        skip(1);
        vm.prank(publisher);
        market.terminatePlacement(placementId);
        vm.expectRevert(IAgentOfferMarket.AlreadyTerminated.selector);
        market.settleExpired(placementId, 0);
    }

    // ---------------------------------------------------------------- termination

    function test_terminate_isPublisherOnlyAndOnce() public {
        vm.expectRevert(IAgentOfferMarket.NotPublisher.selector);
        vm.prank(payout);
        market.terminatePlacement(placementId);

        vm.expectEmit(address(market));
        emit IAgentOfferMarket.PlacementTerminated(placementId, _now());
        vm.prank(publisher);
        market.terminatePlacement(placementId);
        assertEq(market.getPlacement(placementId).terminatedAt, _now());

        vm.expectRevert(IAgentOfferMarket.AlreadyTerminated.selector);
        vm.prank(publisher);
        market.terminatePlacement(placementId);
    }

    function test_terminate_closesBuying() public {
        vm.prank(publisher);
        market.terminatePlacement(placementId);

        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, placementId, 0, FLOOR);
        _expectBuyRevert(
            alice, p, _permit(market, p, alice), abi.encodeWithSelector(IAgentOfferMarket.AlreadyTerminated.selector)
        );
        vm.expectRevert(IAgentOfferMarket.AlreadyTerminated.selector);
        market.minimumPrice(placementId, 0);
    }

    function test_terminate_refundsFromItsOwnMomentHoweverLateTheSettlement() public {
        _buy(market, alice, placementId, 0, 7_200_000);
        skip(12 hours);
        _buy(market, bob, placementId, 1, 7_200_000);
        skip(6 hours);
        vm.prank(publisher);
        market.terminatePlacement(placementId);
        uint64 terminatedAt = _now();

        skip(30 days);
        // Alice used 18 of 72 hours, Bob 6 of 72.
        vm.expectEmit(address(market));
        emit IAgentOfferMarket.LeaseSettled(
            placementId,
            0,
            alice,
            1,
            IAgentOfferMarket.SettleReason.Terminated,
            terminatedAt,
            5_400_000,
            1_620_000,
            180_000
        );
        vm.prank(stranger);
        market.settleTerminated(placementId, 0);
        market.settleTerminated(placementId, 1);

        assertEq(market.claimable(alice), 5_400_000);
        assertEq(market.claimable(bob), 6_600_000);
        assertEq(market.claimable(payout), 1_620_000 + 540_000);
        assertEq(market.revenueOwed(), 180_000 + 60_000);
        assertEq(market.totalLeaseDeposits(), 0);

        // Again, and on a slot never sold: nothing changes.
        vm.recordLogs();
        market.settleTerminated(placementId, 0);
        market.settleTerminated(placementId, 2);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_lease(0).nonce, 1);
        _assertBooks(market);
    }

    function test_terminate_leavesALeaseThatRanOutBeforeItFullyEarned() public {
        _buy(market, alice, placementId, 0, FLOOR);
        skip(DURATION + 1 hours);
        vm.prank(publisher);
        market.terminatePlacement(placementId);

        market.settleTerminated(placementId, 0);
        assertEq(market.claimable(alice), 0);
        assertEq(market.claimable(payout), 4_500_000);
        _assertBooks(market);
    }

    function test_terminate_inTheSecondOfAPurchaseRefundsItAll() public {
        _buy(market, alice, placementId, 0, FLOOR);
        vm.prank(publisher);
        market.terminatePlacement(placementId);
        market.settleTerminated(placementId, 0);
        assertEq(market.claimable(alice), FLOOR);
        assertEq(market.claimable(payout), 0);
    }

    function test_settleTerminated_refusesAnOpenPlacement() public {
        vm.expectRevert(IAgentOfferMarket.NotTerminated.selector);
        market.settleTerminated(placementId, 0);
    }

    function test_changedTerms_terminateThenCreateANewPlacement() public {
        _buy(market, alice, placementId, 0, FLOOR);
        skip(1 days);
        vm.startPrank(publisher);
        market.terminatePlacement(placementId);
        uint256 next = market.createPlacement(SOURCE, _terms(5, 24 hours, 2_000, 1_000_000), "ipfs://v2");
        vm.stopPrank();

        _buy(market, bob, next, 4, 1_000_000);
        assertEq(market.minimumPrice(next, 4), 1_200_000);
        market.settleTerminated(placementId, 0);
        assertEq(market.claimable(alice), 3_333_333);
        _assertBooks(market);
    }

    // ---------------------------------------------------------------- claims

    function test_claim_sendsAllTheCallersCreditOnceToItsRecipient() public {
        _buy(market, alice, placementId, 0, FLOOR);
        _buy(market, bob, placementId, 0, 5_500_000);
        address elsewhere = makeAddr("elsewhere");

        vm.expectEmit(address(market));
        emit IAgentOfferMarket.Claimed(alice, elsewhere, FLOOR);
        vm.prank(alice);
        assertEq(market.claim(elsewhere), FLOOR);
        assertEq(usdc.balanceOf(elsewhere), FLOOR);
        assertEq(market.claimable(alice), 0);
        assertEq(market.totalClaimable(), 0);

        vm.expectRevert(IAgentOfferMarket.NothingOwed.selector);
        vm.prank(alice);
        market.claim(alice);
        _assertBooks(market);
    }

    function test_claim_refusesTheZeroAddressAndTheMarket() public {
        _buy(market, alice, placementId, 0, FLOOR);
        _buy(market, bob, placementId, 0, 5_500_000);
        vm.startPrank(alice);
        vm.expectRevert(IAgentOfferMarket.InvalidRecipient.selector);
        market.claim(address(0));
        vm.expectRevert(IAgentOfferMarket.InvalidRecipient.selector);
        market.claim(address(market));
        vm.stopPrank();
    }

    function test_aFrozenWalletBlocksOnlyItsOwnClaim() public {
        _buy(market, alice, placementId, 0, FLOOR);
        usdc.freeze(alice, true);
        usdc.freeze(payout, true);

        // Bob buys Alice out and Carol buys Bob out; a frozen old holder or payout holds up neither.
        skip(1 hours);
        _buy(market, bob, placementId, 0, 5_500_000);
        skip(1 hours);
        _buy(market, carol, placementId, 0, 6_050_000);
        uint256 aliceOwed = market.claimable(alice);
        uint256 payoutOwed = market.claimable(payout);
        uint256 bobOwed = market.claimable(bob);
        assertGt(aliceOwed, 0);
        assertGt(payoutOwed, 0);
        assertGt(bobOwed, 0);

        // Alice and the payout wallet cannot receive...
        vm.expectRevert("FROZEN");
        vm.prank(alice);
        market.claim(alice);
        vm.expectRevert("FROZEN");
        vm.prank(payout);
        market.claim(payout);

        // ...while everyone else's money moves...
        vm.prank(bob);
        assertEq(market.claim(bob), bobOwed);
        uint256 owed = market.revenueOwed();
        assertEq(market.pushRevenue(), owed);
        _buy(market, makeAddr("dave"), placementId, 1, FLOOR);

        // ...and a frozen wallet's credit can still go to another wallet of its own.
        address aliceNew = makeAddr("alice-new");
        address payoutNew = makeAddr("payout-new");
        vm.prank(alice);
        market.claim(aliceNew);
        vm.prank(payout);
        market.claim(payoutNew);
        assertEq(usdc.balanceOf(aliceNew), aliceOwed);
        assertEq(usdc.balanceOf(payoutNew), payoutOwed);
        _assertBooks(market);
    }

    // ---------------------------------------------------------------- revenue

    function test_pushRevenue_depositsAllOwedTaggedForAnyCaller() public {
        _buy(market, alice, placementId, 0, 6_000_000);
        skip(DURATION);
        market.settleExpired(placementId, 0);

        vm.expectEmit(address(market));
        emit IAgentOfferMarket.RevenuePushed(stranger, 600_000);
        vm.prank(stranger);
        assertEq(market.pushRevenue(), 600_000);
        assertEq(usdc.balanceOf(address(staking)), 600_000);
        assertEq(staking.lastSourceTag(), bytes32("agent.offers"));
        assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(market)))));
        assertEq(usdc.allowance(address(market), address(staking)), 0);

        vm.expectRevert(IAgentOfferMarket.NothingOwed.selector);
        market.pushRevenue();
        _assertBooks(market);
    }

    function test_aPausedStakingContractHoldsUpOnlyThePush() public {
        _buy(market, alice, placementId, 0, 6_000_000);
        skip(DURATION);
        staking.setPaused(true);

        _buy(market, bob, placementId, 0, FLOOR);
        vm.expectRevert("PAUSED");
        market.pushRevenue();
        assertEq(market.revenueOwed(), 600_000);
        vm.prank(payout);
        market.claim(payout);

        staking.setPaused(false);
        assertEq(market.pushRevenue(), 600_000);
        _assertBooks(market);
    }

    // ---------------------------------------------------------------- arithmetic, fuzzed

    /// @dev Any payment, any step, any moment of a buyout: the refund is the unused share rounded
    ///      down, never more than was paid, and refund, earnings and fee add up to the payment.
    function testFuzz_buyout_splitsThePaymentExactly(uint256 paid, uint256 elapsed, uint16 bump, uint16 fee) public {
        paid = bound(paid, FLOOR, 1e15);
        elapsed = bound(elapsed, 0, DURATION - 1);
        bump = uint16(bound(bump, 1, 10_000));
        fee = uint16(bound(fee, 0, 2_000));
        AgentOfferMarket m = _marketWithFee(fee);
        vm.prank(publisher);
        uint256 id = m.createPlacement(SOURCE, _terms(1, DURATION, bump, FLOOR), "");

        _buy(m, alice, id, 0, paid);
        skip(elapsed);
        uint256 minimum = m.minimumPrice(id, 0);
        _buy(m, bob, id, 0, minimum);

        uint256 refund = m.claimable(alice);
        uint256 earned = paid - refund;
        assertLe(refund, paid);
        assertEq(refund, (paid * (DURATION - elapsed)) / DURATION);
        assertEq(m.revenueOwed(), (earned * fee) / 10_000);
        assertEq(refund + m.claimable(payout) + m.revenueOwed(), paid);
        _assertBooks(m);
    }

    /// @dev The buyout minimum is the smallest whole amount at least the step above the payment.
    function testFuzz_minimum_isTheStepRoundedUp(uint256 paid, uint16 bump, uint256 elapsed) public {
        paid = bound(paid, FLOOR, type(uint128).max / 2);
        bump = uint16(bound(bump, 1, 10_000));
        elapsed = bound(elapsed, 0, DURATION - 1);
        vm.prank(publisher);
        uint256 id = market.createPlacement(SOURCE, _terms(1, DURATION, bump, FLOOR), "");
        _buy(market, alice, id, 0, paid);
        skip(elapsed);

        uint256 minimum = market.minimumPrice(id, 0);
        uint256 target = paid * (10_000 + uint256(bump));
        assertGe(minimum * 10_000, target);
        assertLt((minimum - 1) * 10_000, target);
        assertGt(minimum, paid);

        if (minimum <= type(uint128).max) {
            IAgentOfferMarket.Purchase memory p = _purchase(market, bob, id, 0, minimum - 1);
            _expectBuyRevert(
                bob,
                p,
                _permit(market, p, bob),
                abi.encodeWithSelector(IAgentOfferMarket.AmountBelowMinimum.selector, minimum)
            );
            _buy(market, bob, id, 0, minimum);
            assertEq(market.getLease(id, 0).buyer, bob);
        }
    }

    /// @dev Termination charges every lease up to the termination, however long settling waits.
    function testFuzz_terminate_refundsFromTheFrozenMoment(uint256 paid, uint256 before, uint256 later) public {
        paid = bound(paid, FLOOR, 1e15);
        before = bound(before, 0, 2 * uint256(DURATION));
        later = bound(later, 0, 365 days);
        _buy(market, alice, placementId, 0, paid);
        skip(before);
        vm.prank(publisher);
        market.terminatePlacement(placementId);
        skip(later);
        market.settleTerminated(placementId, 0);

        uint256 left = before >= DURATION ? 0 : DURATION - before;
        assertEq(market.claimable(alice), (paid * left) / DURATION);
        assertEq(market.claimable(alice) + market.claimable(payout) + market.revenueOwed(), paid);
        _assertBooks(market);
    }

    /// @dev A chain of buyouts at random moments and prices, then expiry and every claim and push:
    ///      everything paid in comes out, to the unit, and the market is left empty.
    function testFuzz_aChainOfBuyoutsCreatesAndLosesNothing(uint256 seed) public {
        address[3] memory buyers = [alice, bob, carol];
        uint256 paidIn;
        for (uint256 i; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            skip(r % (DURATION + 1 hours));
            uint256 amount = market.minimumPrice(placementId, 0) + (r >> 64) % 3_000_000;
            _buy(market, buyers[i % 3], placementId, 0, amount);
            paidIn += amount;
        }
        skip(DURATION);
        market.settleExpired(placementId, 0);

        uint256 paidOut;
        address[4] memory accounts = [alice, bob, carol, payout];
        for (uint256 i; i < accounts.length; ++i) {
            if (market.claimable(accounts[i]) == 0) continue;
            vm.prank(accounts[i]);
            paidOut += market.claim(accounts[i]);
        }
        paidOut += market.pushRevenue();
        assertEq(paidOut, paidIn);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(market.totalLeaseDeposits() + market.totalClaimable() + market.revenueOwed(), 0);
    }

    /// @dev A second market from a factory with another fee, sharing the same token.
    function _marketWithFee(uint16 fee) internal returns (AgentOfferMarket m) {
        m = AgentOfferMarket(Clones.clone(factory.implementation()));
        m.initialize(
            IAgentOfferMarket.Init({
                usdc: IERC20(BASE_USDC), publisher: publisher, payout: payout, staking: staking, feeBps: fee
            })
        );
    }
}

/// @notice A buyer that calls back into the market from inside a token transfer, once.
contract Reenterer is ITransferHook {
    enum Attack {
        Claim,
        Settle
    }

    AgentOfferMarket internal immutable market;
    bool internal armed;
    Attack internal attack;
    uint256 internal placementId;
    bytes public reentryError;

    constructor(AgentOfferMarket market_, IERC20 token) {
        market = market_;
        token.approve(address(market_), type(uint256).max);
    }

    function arm(Attack attack_, uint256 placementId_) external {
        armed = true;
        attack = attack_;
        placementId = placementId_;
    }

    function buy(IAgentOfferMarket.Purchase calldata p, bytes calldata permit) external {
        market.buy(p, permit);
    }

    function claim() external returns (uint256) {
        return market.claim(address(this));
    }

    function onTokenTransfer() external {
        if (!armed) return;
        armed = false;
        if (attack == Attack.Claim) {
            try market.claim(address(this)) {}
            catch (bytes memory reason) {
                reentryError = reason;
            }
        } else {
            try market.settleExpired(placementId, 0) {}
            catch (bytes memory reason) {
                reentryError = reason;
            }
        }
    }
}

/// @title AgentOfferMarketReentrancyTest
/// @notice A token that calls back mid-transfer gains nothing: every call that moves or credits
///         money is guarded, and credit is cleared before it is sent.
contract AgentOfferMarketReentrancyTest is AgentOfferBase {
    HookUSDC internal token;
    Reenterer internal attacker;
    uint256 internal placementId;

    function setUp() public {
        _deploy(new HookUSDC());
        token = HookUSDC(BASE_USDC);
        placementId = _patchbayPlacement(market);
        attacker = new Reenterer(market, IERC20(BASE_USDC));
        token.hook(address(attacker));
    }

    /// @dev The attacker buys slot 0, armed to call back while the market pulls its payment. It is
    ///      armed only after its USDC is minted, since the mint itself calls the hook.
    function _attackerBuy(uint256 amount, bool armed) internal {
        IAgentOfferMarket.Purchase memory p = _purchase(market, address(attacker), placementId, 0, amount);
        bytes memory permit = _permit(market, p, address(attacker));
        token.mint(address(attacker), amount);
        if (armed) attacker.arm(Reenterer.Attack.Settle, placementId);
        attacker.buy(p, permit);
    }

    function test_aReentrantClaimPaysNothingTwice() public {
        _attackerBuy(FLOOR, false);
        _buy(market, makeAddr("bob"), placementId, 0, 5_500_000);
        assertEq(market.claimable(address(attacker)), FLOOR);

        attacker.arm(Reenterer.Attack.Claim, placementId);
        assertEq(attacker.claim(), FLOOR);

        assertEq(
            attacker.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(token.balanceOf(address(attacker)), FLOOR);
        assertEq(market.claimable(address(attacker)), 0);
        _assertBooks(market);
    }

    function test_aCallBackDuringTheBuyPullIsRefused() public {
        _buy(market, makeAddr("bob"), placementId, 0, FLOOR);
        skip(DURATION);

        _attackerBuy(FLOOR, true);

        assertEq(
            attacker.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(market.getLease(placementId, 0).buyer, address(attacker));
        assertEq(market.getLease(placementId, 0).nonce, 2);
        _assertBooks(market);
    }
}

/// @notice Drives one market through random purchases, buyouts, settlements, terminations with new
///         placements, claims to any recipient, pushes, freezes, a paused staking contract, USDC
///         sent straight to the market, and the passing of time. Every call that should succeed is
///         made without a catch, so the suite's fail-on-revert flags any unexpected refusal.
contract MarketHandler is Test {
    uint256 internal constant MAX_PLACEMENTS = 8;

    AgentOfferMarket internal immutable market;
    FreezableUSDC internal immutable usdc;
    RecordingStaking internal immutable staking;
    address internal immutable publisher;
    uint256 internal immutable publisherKey;
    address[] internal buyers;
    address[] internal recipients;
    uint256[] public placementIds;

    /// @notice Every unit paid in by buyers, sent in directly, claimed out and pushed out.
    uint256 public paidIn;
    uint256 public donated;
    uint256 public claimedOut;
    uint256 public pushedOut;

    /// @notice How many leases each slot has sold, counted here independently of the market.
    mapping(uint256 placementId => mapping(uint16 slot => uint64 sold)) public sold;

    /// @notice How often each path took effect in this run, so the suite can show every path ran.
    mapping(string path => uint256 count) public reached;

    constructor(
        AgentOfferMarket market_,
        FreezableUSDC usdc_,
        RecordingStaking staking_,
        uint256 publisherKey_,
        address[] memory buyers_,
        address[] memory recipients_,
        uint256[] memory placementIds_
    ) {
        market = market_;
        usdc = usdc_;
        staking = staking_;
        publisher = vm.addr(publisherKey_);
        publisherKey = publisherKey_;
        buyers = buyers_;
        recipients = recipients_;
        placementIds = placementIds_;
    }

    function placementCount() external view returns (uint256) {
        return placementIds.length;
    }

    /// @dev Buys a random slot of a random open placement at its minimum plus a little, as a
    ///      buyer the token has not frozen, with a valid admission. It must never revert.
    function buy(uint256 buyerSeed, uint256 placementSeed, uint256 slotSeed, uint256 extra) external {
        uint256 id = placementIds[placementSeed % placementIds.length];
        IAgentOfferMarket.Placement memory placement = market.getPlacement(id);
        if (placement.terminatedAt != 0) return;
        _buy(buyerSeed, id, uint16(slotSeed % placement.terms.capacity), extra);
    }

    /// @dev Makes sure a slot is held, then buys it out partway through its term. Random waits
    ///      alone let most leases run out before the next purchase, so this keeps buyouts in every
    ///      run.
    function buyout(uint256 buyerSeed, uint256 placementSeed, uint256 slotSeed, uint256 elapsed, uint256 extra)
        external
    {
        uint256 id = placementIds[placementSeed % placementIds.length];
        IAgentOfferMarket.Placement memory placement = market.getPlacement(id);
        if (placement.terminatedAt != 0) return;
        uint16 slot = uint16(slotSeed % placement.terms.capacity);
        if (vm.getBlockTimestamp() >= market.getLease(id, slot).endsAt) _buy(buyerSeed, id, slot, extra);
        uint256 endsAt = market.getLease(id, slot).endsAt;
        // No purchase happened if every buyer is frozen.
        if (vm.getBlockTimestamp() >= endsAt) return;
        skip(bound(elapsed, 0, endsAt - vm.getBlockTimestamp() - 1));
        _buy(buyerSeed % buyers.length + 1, id, slot, extra);
    }

    function _buy(uint256 buyerSeed, uint256 id, uint16 slot, uint256 extra) internal {
        address buyer = _unfrozenBuyer(buyerSeed);
        if (buyer == address(0)) return;

        IAgentOfferMarket.Lease memory before = market.getLease(id, slot);
        uint256 minimum = market.minimumPrice(id, slot);
        // A placement that doubles on every buyout could in theory climb past any budget.
        if (minimum > 1e18) return;
        uint256 amount = minimum + bound(extra, 0, 10_000_000);
        IAgentOfferMarket.Purchase memory p = IAgentOfferMarket.Purchase({
            placementId: id,
            slot: slot,
            campaignId: keccak256(abi.encode(buyer, extra)),
            amountUSDC: SafeCast.toUint128(amount),
            expectedLeaseNonce: before.nonce,
            deadline: SafeCast.toUint64(vm.getBlockTimestamp())
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherKey, market.eligibilityDigest(p, buyer));

        usdc.mint(buyer, amount);
        vm.startPrank(buyer);
        usdc.approve(address(market), amount);
        market.buy(p, abi.encodePacked(r, s, v));
        vm.stopPrank();

        paidIn += amount;
        sold[id][slot] += 1;
        if (before.paidUSDC == 0) reached["empty slot"] += 1;
        else if (vm.getBlockTimestamp() < before.endsAt) reached["buyout"] += 1;
        else reached["run-out slot"] += 1;
    }

    function settleExpired(uint256 placementSeed, uint256 slotSeed) external {
        uint256 id = placementIds[placementSeed % placementIds.length];
        IAgentOfferMarket.Placement memory placement = market.getPlacement(id);
        uint16 slot = uint16(slotSeed % placement.terms.capacity);
        IAgentOfferMarket.Lease memory lease = market.getLease(id, slot);
        if (placement.terminatedAt != 0 || (lease.paidUSDC != 0 && vm.getBlockTimestamp() < lease.endsAt)) return;

        market.settleExpired(id, slot);
        if (lease.paidUSDC != 0) reached["settle expired"] += 1;
    }

    /// @dev Terminates a random open placement that holds a lease, so every termination has
    ///      something to refund, and opens a replacement with the same terms. Up to a limit, so
    ///      buying never stops and the books stay small enough to sum. Terminating an empty
    ///      placement is covered by the unit tests.
    function terminate(uint256 placementSeed) external {
        if (placementIds.length >= MAX_PLACEMENTS) return;
        uint256 id = placementIds[placementSeed % placementIds.length];
        IAgentOfferMarket.Placement memory placement = market.getPlacement(id);
        if (placement.terminatedAt != 0 || _heldSlot(id) == type(uint256).max) return;

        vm.startPrank(publisher);
        market.terminatePlacement(id);
        placementIds.push(market.createPlacement(placement.sourceId, placement.terms, ""));
        vm.stopPrank();
        reached["terminate"] += 1;
    }

    /// @dev Settles the first held slot of any terminated placement, or a random slot of a random
    ///      terminated one (which changes nothing) when none is held.
    function settleTerminated(uint256 placementSeed, uint256 slotSeed) external {
        for (uint256 i; i < placementIds.length; ++i) {
            uint256 held = _heldSlot(placementIds[i]);
            if (market.getPlacement(placementIds[i]).terminatedAt != 0 && held != type(uint256).max) {
                market.settleTerminated(placementIds[i], uint16(held));
                reached["settle terminated"] += 1;
                return;
            }
        }
        uint256 id = placementIds[placementSeed % placementIds.length];
        IAgentOfferMarket.Placement memory placement = market.getPlacement(id);
        if (placement.terminatedAt != 0) market.settleTerminated(id, uint16(slotSeed % placement.terms.capacity));
    }

    /// @dev The first slot of a placement holding an unsettled lease, or the largest uint if none.
    function _heldSlot(uint256 id) internal view returns (uint256) {
        uint16 capacity = market.getPlacement(id).terms.capacity;
        for (uint16 slot; slot < capacity; ++slot) {
            if (market.getLease(id, slot).paidUSDC != 0) return slot;
        }
        return type(uint256).max;
    }

    /// @dev Claims a random account's credit to itself or another recipient. Only a frozen
    ///      recipient may refuse it, and then the same credit goes to a wallet that is not frozen.
    function claim(uint256 accountSeed, uint256 recipientSeed, bool toSelf) external {
        address account = accountSeed % (buyers.length + 1) == buyers.length
            ? market.payout()
            : buyers[accountSeed % (buyers.length + 1)];
        address recipient = toSelf ? account : recipients[recipientSeed % recipients.length];
        uint256 owed = market.claimable(account);
        if (owed == 0) return;

        vm.prank(account);
        try market.claim(recipient) returns (uint256 amount) {
            assertEq(amount, owed);
            claimedOut += amount;
            reached["claim"] += 1;
        } catch {
            assertTrue(usdc.frozen(recipient), "only a frozen recipient may refuse a claim");
            // recipients[0] is never frozen.
            vm.prank(account);
            assertEq(market.claim(recipients[0]), owed);
            claimedOut += owed;
            reached["claim elsewhere"] += 1;
        }
    }

    function pushRevenue() external {
        uint256 owed = market.revenueOwed();
        if (owed == 0) return;
        try market.pushRevenue() returns (uint256 amount) {
            assertEq(amount, owed);
            pushedOut += amount;
            reached["push"] += 1;
        } catch {
            assertTrue(staking.paused(), "only a paused staking contract may refuse a push");
        }
    }

    function freeze(uint256 accountSeed, bool frozen) external {
        uint256 i = accountSeed % (buyers.length + 1);
        usdc.freeze(i == buyers.length ? market.payout() : buyers[i], frozen);
    }

    function pauseStaking(bool paused) external {
        staking.setPaused(paused);
    }

    /// @dev USDC sent straight to the market; it is never anyone's credit and never leaves.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000);
        usdc.mint(address(market), amount);
        donated += amount;
    }

    function wait(uint256 seconds_) external {
        skip(bound(seconds_, 0, 4 days));
    }

    function _unfrozenBuyer(uint256 seed) internal view returns (address) {
        for (uint256 i; i < buyers.length; ++i) {
            address candidate = buyers[(seed % buyers.length + i) % buyers.length];
            if (!usdc.frozen(candidate)) return candidate;
        }
        return address(0);
    }
}

/// @title AgentOfferMarketInvariantTest
/// @notice Whatever happens: the USDC held covers every unsettled lease, every credit and the
///         revenue owed; the market's running totals equal the sums of what they total; no unit is
///         created or lost; every slot's nonce counts exactly the leases it sold; and every lease is
///         well formed.
contract AgentOfferMarketInvariantTest is AgentOfferBase {
    MarketHandler internal handler;
    address[] internal accounts;

    function setUp() public {
        _deploy(new FreezableUSDC());

        uint256[] memory ids = new uint256[](3);
        vm.startPrank(publisher);
        ids[0] = market.createPlacement(SOURCE, _terms(CAPACITY, DURATION, BUMP_BPS, FLOOR), "");
        ids[1] = market.createPlacement(keccak256("other.site"), _terms(2, 1 hours, 1, 1), "");
        ids[2] = market.createPlacement(keccak256("third.site"), _terms(1, 10 minutes, 10_000, 123_456), "");
        vm.stopPrank();

        address[] memory buyers = new address[](4);
        address[] memory recipients = new address[](2);
        for (uint256 i; i < buyers.length; ++i) {
            buyers[i] = makeAddr(string.concat("buyer-", vm.toString(i)));
            accounts.push(buyers[i]);
        }
        accounts.push(payout);
        recipients[0] = makeAddr("recipient-0");
        recipients[1] = buyers[0];

        handler = new MarketHandler(market, usdc, staking, publisherKey, buyers, recipients, ids);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_reserveCoversEveryLeaseCreditAndFee() public view {
        uint256 reserved = market.totalLeaseDeposits() + market.totalClaimable() + market.revenueOwed();
        assertGe(usdc.balanceOf(address(market)), reserved);
        assertEq(usdc.balanceOf(address(market)), reserved + handler.donated());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_nothingIsCreatedOrLost() public view {
        assertEq(
            handler.paidIn() + handler.donated(),
            usdc.balanceOf(address(market)) + handler.claimedOut() + handler.pushedOut()
        );
        assertEq(usdc.balanceOf(address(staking)), handler.pushedOut());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalsMatchTheLedger() public view {
        uint256 credits;
        for (uint256 i; i < accounts.length; ++i) {
            credits += market.claimable(accounts[i]);
        }
        assertEq(market.totalClaimable(), credits);

        uint256 deposits;
        for (uint256 i; i < handler.placementCount(); ++i) {
            uint256 id = handler.placementIds(i);
            IAgentOfferMarket.Placement memory placement = market.getPlacement(id);
            for (uint16 slot; slot < placement.terms.capacity; ++slot) {
                IAgentOfferMarket.Lease memory lease = market.getLease(id, slot);
                deposits += lease.paidUSDC;
                assertEq(lease.nonce, handler.sold(id, slot), "nonce counts sales");
                if (lease.paidUSDC == 0) {
                    assertEq(lease.buyer, address(0));
                    assertEq(lease.endsAt, 0);
                } else {
                    assertTrue(lease.buyer != address(0));
                    assertGe(lease.paidUSDC, placement.terms.floorUSDC);
                    assertEq(lease.endsAt - lease.startsAt, placement.terms.durationSeconds);
                    if (placement.terminatedAt != 0) assertLe(lease.startsAt, placement.terminatedAt);
                }
            }
        }
        assertEq(market.totalLeaseDeposits(), deposits);
    }

    /// @dev Proves each run reached every way money moves, not only refused or skipped calls. A
    ///      claim refused by a frozen recipient and then sent elsewhere ("claim elsewhere") needs a
    ///      frozen account with credit to claim to itself, which a random run does not always
    ///      produce, so it is counted, not required; a unit test covers it directly.
    function afterInvariant() external view {
        string[8] memory paths = [
            "empty slot", "buyout", "run-out slot", "settle expired", "terminate", "settle terminated", "claim", "push"
        ];
        for (uint256 i; i < paths.length; ++i) {
            assertGt(handler.reached(paths[i]), 0, paths[i]);
        }
    }
}
