// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RegentOffers} from "../src/RegentOffers.sol";
import {OffersTestUSDC, OffersTestStaking, OffersTestWallet} from "./OffersTestTokens.sol";

/// @notice Shared set-up: a venue, a bidder key and a way to sign a bid's USDC authorization.
abstract contract OffersSetUp is Test {
    OffersTestUSDC internal usdc;
    OffersTestStaking internal staking;
    RegentOffers internal offers;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("venue admin");
    address internal operator = makeAddr("operator");
    address internal payout = makeAddr("payout");
    address internal stranger = makeAddr("stranger");

    uint256 internal bidderKey = 0xB1D;
    address internal bidder;

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    bytes32 internal constant SLOT = keccak256("keyfleet.ai#1");
    uint96 internal constant MINIMUM = 1_000_000;
    uint32 internal constant LENGTH = 72 hours;
    uint256 internal constant PROTOCOL_BPS = 1000;

    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 internal salts;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        bidder = vm.addr(bidderKey);
        usdc = new OffersTestUSDC();
        staking = new OffersTestStaking(usdc);
        offers = new RegentOffers(usdc, staking, PROTOCOL_BPS, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, payout, MINIMUM, LENGTH);
        usdc.mint(bidder, 1_000_000_000_000);
    }

    function terms(bytes32 slot, uint96 amount) internal returns (RegentOffers.Terms memory t) {
        t = RegentOffers.Terms({
            venue: VENUE,
            slot: slot,
            lane: 0,
            wordingHash: keccak256("wording v1"),
            amount: amount,
            length: LENGTH,
            placeBy: uint64(vm.getBlockTimestamp() + 1 hours),
            salt: bytes32(++salts)
        });
    }

    function sign(uint256 key, address from, RegentOffers.Terms memory t) internal view returns (bytes memory) {
        bytes32 nonce = keccak256(abi.encode(t));
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_TYPEHASH,
                from,
                address(offers),
                t.amount,
                uint256(0),
                vm.getBlockTimestamp() + 10 minutes,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function submit(RegentOffers.Terms memory t, bytes memory signature) internal returns (bytes32) {
        vm.prank(operator);
        return offers.bid(t, bidder, 0, vm.getBlockTimestamp() + 10 minutes, signature);
    }

    function bidOn(bytes32 slot, uint96 amount) internal returns (bytes32) {
        RegentOffers.Terms memory t = terms(slot, amount);
        return submit(t, sign(bidderKey, bidder, t));
    }

    function placed(bytes32 slot, uint96 amount) internal returns (bytes32 id) {
        id = bidOn(slot, amount);
        vm.prank(operator);
        offers.place(id);
    }

    function status(bytes32 id) internal view returns (RegentOffers.Status s) {
        (,,,,,,, s) = offers.bids(id);
    }

    function startsAt(bytes32 id) internal view returns (uint64 s) {
        (,,,,, s,,) = offers.bids(id);
    }
}

/// @title RegentOffersTest
/// @notice A signature funds only the exact bid it names, once; bid money leaves only back to its
///         bidder or as payment for its placement, split as the constructor set; the operator cannot
///         set a start time or keep two placements in a slot; and ending never depends on paying.
contract RegentOffersTest is OffersSetUp {
    // ------------------------------------------------------------ bidding

    function test_bid_pulls_exactly_the_amount_and_holds_it() public {
        uint256 before = usdc.balanceOf(bidder);
        bytes32 id = bidOn(SLOT, 5_000_000);
        assertEq(usdc.balanceOf(bidder), before - 5_000_000);
        assertEq(usdc.balanceOf(address(offers)), 5_000_000);
        assertEq(offers.totalCommitted(), 5_000_000);
        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Held));
    }

    function test_bid_id_and_nonce_are_what_the_contract_says() public {
        RegentOffers.Terms memory t = terms(SLOT, MINIMUM);
        bytes32 id = submit(t, sign(bidderKey, bidder, t));
        assertEq(id, offers.bidIdOf(bidder, t));
        assertEq(offers.nonceOf(t), keccak256(abi.encode(t)));
    }

    function test_anyone_may_submit_a_signed_bid() public {
        RegentOffers.Terms memory t = terms(SLOT, MINIMUM);
        bytes memory signature = sign(bidderKey, bidder, t);
        vm.prank(stranger);
        bytes32 id = offers.bid(t, bidder, 0, vm.getBlockTimestamp() + 10 minutes, signature);
        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Held));
    }

    function test_a_signature_funds_its_bid_once() public {
        RegentOffers.Terms memory t = terms(SLOT, MINIMUM);
        bytes memory signature = sign(bidderKey, bidder, t);
        submit(t, signature);
        vm.expectRevert(RegentOffers.BidExists.selector);
        submit(t, signature);
    }

    /// Any change to any term gives another nonce, which the bidder never signed.
    function testFuzz_a_signature_funds_only_its_exact_terms(uint8 field, uint96 delta) public {
        RegentOffers.Terms memory t = terms(SLOT, 10_000_000);
        bytes memory signature = sign(bidderKey, bidder, t);
        delta = uint96(bound(delta, 1, 1_000_000));
        field = uint8(bound(field, 0, 6));
        if (field == 0) t.slot = keccak256("another slot");
        if (field == 1) t.lane = 1;
        if (field == 2) t.wordingHash = keccak256("other wording");
        if (field == 3) t.amount += delta;
        if (field == 4) t.placeBy += 1;
        if (field == 5) t.salt = keccak256("other salt");
        if (field == 6) t.amount -= delta;
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        submit(t, signature);
    }

    function test_a_signature_is_bidders_own() public {
        RegentOffers.Terms memory t = terms(SLOT, MINIMUM);
        bytes memory signature = sign(0xBAD, vm.addr(0xBAD), t);
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        submit(t, signature);
    }

    function test_a_contract_wallet_bids_through_erc1271() public {
        OffersTestWallet wallet = new OffersTestWallet(bidder);
        usdc.mint(address(wallet), 10_000_000);
        RegentOffers.Terms memory t = terms(SLOT, MINIMUM);
        bytes memory signature = sign(bidderKey, address(wallet), t);
        vm.prank(operator);
        bytes32 id = offers.bid(t, address(wallet), 0, vm.getBlockTimestamp() + 10 minutes, signature);
        (address who,,,,,,,) = offers.bids(id);
        assertEq(who, address(wallet));
    }

    function test_bid_refusals() public {
        RegentOffers.Terms memory t = terms(SLOT, MINIMUM - 1);
        bytes memory signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.BelowMinimum.selector);
        submit(t, signature);

        t = terms(SLOT, MINIMUM);
        t.length = LENGTH + 1;
        signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.LengthMismatch.selector);
        submit(t, signature);

        t = terms(SLOT, MINIMUM);
        t.placeBy = uint64(vm.getBlockTimestamp());
        signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.PlaceByPassed.selector);
        submit(t, signature);

        t = terms(SLOT, MINIMUM);
        t.venue = keccak256("unknown venue");
        signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.VenueNotFound.selector);
        submit(t, signature);

        t = terms(bytes32(0), MINIMUM);
        signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.ZeroValue.selector);
        submit(t, signature);
    }

    /// Every forum's slots take bids with no listing step.
    function testFuzz_any_slot_of_a_venue_takes_bids(bytes32 slot) public {
        vm.assume(slot != bytes32(0));
        bytes32 id = bidOn(slot, MINIMUM);
        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Held));
    }

    // ------------------------------------------------------------- pausing

    function test_pause_stops_new_bids_and_nothing_else() public {
        bytes32 heldId = bidOn(SLOT, MINIMUM);
        bytes32 showing = placed(keccak256("slot 2"), 2_000_000);
        bytes32 waiting = bidOn(keccak256("slot 3"), 3_000_000);

        vm.prank(owner);
        offers.setPaused(true);

        RegentOffers.Terms memory t = terms(SLOT, MINIMUM);
        bytes memory signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.BidsPaused.selector);
        submit(t, signature);

        vm.startPrank(operator);
        offers.place(heldId);
        offers.returnBid(waiting);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(showing);
        offers.finish(heldId);
        offers.payOut(bidder);
        offers.payOut(payout);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(offers)), 0);
    }

    function test_only_the_owner_pauses_and_the_owner_never_leaves() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        offers.setPaused(true);

        vm.expectRevert(RegentOffers.OwnerRequired.selector);
        vm.prank(owner);
        offers.renounceOwnership();
    }

    // --------------------------------------------------- the operator's bounds

    function test_a_placement_starts_at_the_block_time() public {
        bytes32 id = bidOn(SLOT, MINIMUM);
        vm.warp(vm.getBlockTimestamp() + 17 minutes);
        vm.prank(operator);
        offers.place(id);
        assertEq(startsAt(id), vm.getBlockTimestamp());
    }

    function test_only_the_operator_places_returns_and_removes() public {
        bytes32 id = bidOn(SLOT, MINIMUM);
        vm.startPrank(stranger);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(id);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(id);
        vm.stopPrank();

        vm.prank(operator);
        offers.place(id);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        vm.prank(stranger);
        offers.remove(id);
    }

    function test_a_bid_cannot_be_placed_after_its_place_by() public {
        bytes32 id = bidOn(SLOT, MINIMUM);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(RegentOffers.PlaceByPassed.selector);
        vm.prank(operator);
        offers.place(id);
    }

    function test_a_bid_is_placed_once() public {
        bytes32 id = placed(SLOT, MINIMUM);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        vm.prank(operator);
        offers.place(id);
    }

    /// Placing onto a showing slot ends the showing placement in the same call.
    function testFuzz_one_live_placement_per_slot(uint32 after_) public {
        after_ = uint32(bound(after_, 0, LENGTH * 2));
        bytes32 first = placed(SLOT, 10_000_000);
        vm.warp(vm.getBlockTimestamp() + after_);
        bytes32 second = bidOn(SLOT, 20_000_000);
        vm.prank(operator);
        offers.place(second);

        assertEq(offers.live(VENUE, SLOT), second);
        assertEq(uint8(status(first)), uint8(RegentOffers.Status.Ended));
        uint256 shown = after_ > LENGTH ? LENGTH : after_;
        uint256 paid = (uint256(10_000_000) * shown) / LENGTH;
        assertEq(offers.owed(bidder), 10_000_000 - paid);
    }

    /// A stolen operator key placing every held bid of a slot at one moment charges nothing:
    /// each is replaced before any time has shown.
    function test_cycling_bids_through_a_slot_at_once_charges_nothing() public {
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = bidOn(SLOT, uint96(MINIMUM * (i + 1)));
        }
        vm.startPrank(operator);
        for (uint256 i; i < ids.length; ++i) {
            offers.place(ids[i]);
        }
        vm.stopPrank();
        assertEq(offers.owed(payout), 0);
        assertEq(offers.revenueOwed(), 0);
        assertEq(offers.live(VENUE, SLOT), ids[4]);
    }

    // ------------------------------------------------------------- endings

    function test_return_gives_a_held_bid_back_in_full() public {
        bytes32 id = bidOn(SLOT, 7_000_000);
        vm.prank(operator);
        offers.returnBid(id);
        assertEq(offers.owed(bidder), 7_000_000);
        assertEq(offers.totalCommitted(), 0);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        vm.prank(operator);
        offers.place(id);
    }

    function test_anyone_withdraws_an_unplaced_bid_after_place_by_to_its_bidder() public {
        bytes32 id = bidOn(SLOT, 7_000_000);
        vm.expectRevert(RegentOffers.PlaceByNotPassed.selector);
        vm.prank(stranger);
        offers.withdraw(id);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(stranger);
        offers.withdraw(id);
        uint256 before = usdc.balanceOf(bidder);
        vm.prank(stranger);
        offers.payOut(bidder);
        assertEq(usdc.balanceOf(bidder), before + 7_000_000);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_a_placed_bid_cannot_be_withdrawn() public {
        bytes32 id = placed(SLOT, MINIMUM);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.withdraw(id);
    }

    function test_anyone_finishes_a_placement_whose_time_is_up() public {
        bytes32 id = placed(SLOT, 10_000_000);
        vm.warp(vm.getBlockTimestamp() + LENGTH - 1);
        vm.expectRevert(RegentOffers.NotFinished.selector);
        offers.finish(id);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        offers.finish(id);
        assertEq(offers.owed(payout), 9_000_000);
        assertEq(offers.revenueOwed(), 1_000_000);
        assertEq(offers.owed(bidder), 0);
        assertEq(offers.live(VENUE, SLOT), bytes32(0));
    }

    /// A removal for policy pays the whole bid (Sean, 6 Nov 2026: "we are removing refunds entirely").
    function testFuzz_a_removal_pays_the_whole_bid(uint32 after_) public {
        after_ = uint32(bound(after_, 0, LENGTH));
        bytes32 id = placed(SLOT, 10_000_000);
        vm.warp(vm.getBlockTimestamp() + after_);
        vm.prank(operator);
        offers.remove(id);
        assertEq(offers.owed(bidder), 0);
        assertEq(offers.owed(payout), 9_000_000);
        assertEq(offers.revenueOwed(), 1_000_000);
    }

    /// Paid plus returned is always the bid, and the two shares are always what was paid.
    function testFuzz_split_adds_up(uint96 amount, uint32 length, uint64 shown, uint8 reason) public view {
        amount = uint96(bound(amount, 1, type(uint96).max));
        length = uint32(bound(length, 1, type(uint32).max));
        reason = uint8(bound(reason, 0, 2));
        uint256 start = 1_000;
        (uint256 paid, uint256 returned, uint256 protocolShare, uint256 venueShare) =
            offers.split(amount, start, length, start + shown, RegentOffers.EndReason(reason));
        assertEq(paid + returned, amount);
        assertEq(protocolShare + venueShare, paid);
        assertEq(protocolShare, (paid * PROTOCOL_BPS) / 10_000);
        if (reason != uint8(RegentOffers.EndReason.Replaced) || shown >= length) assertEq(paid, amount);
    }

    // ------------------------------------------------------------- payouts

    /// An address USDC will not pay never stops its placement ending or the slot moving on.
    function test_a_blocked_bidder_never_jams_a_slot() public {
        bytes32 first = placed(SLOT, 10_000_000);
        usdc.setBlocked(bidder, true);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        address other = vm.addr(0xC0FFEE);
        usdc.mint(other, 50_000_000);
        RegentOffers.Terms memory t = terms(SLOT, 20_000_000);
        bytes memory signature = sign(0xC0FFEE, other, t);
        vm.startPrank(operator);
        bytes32 second = offers.bid(t, other, 0, vm.getBlockTimestamp() + 10 minutes, signature);
        offers.place(second);
        vm.stopPrank();

        assertEq(uint8(status(first)), uint8(RegentOffers.Status.Ended));
        assertEq(offers.live(VENUE, SLOT), second);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        offers.payOut(bidder);
        offers.payOut(payout);
        assertGt(offers.owed(bidder), 0);
    }

    function test_pay_out_pays_only_the_named_account_once() public {
        bytes32 id = bidOn(SLOT, 3_000_000);
        vm.prank(operator);
        offers.returnBid(id);
        vm.prank(stranger);
        assertEq(offers.payOut(bidder), 3_000_000);
        vm.expectRevert(RegentOffers.NothingOwed.selector);
        offers.payOut(bidder);
        assertEq(offers.totalOwed(), 0);
    }

    function test_revenue_waits_out_a_paused_staking_contract() public {
        bytes32 id = placed(SLOT, 10_000_000);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        staking.setPaused(true);
        vm.expectRevert(bytes("PAUSED"));
        offers.pushRevenue();
        assertEq(offers.revenueOwed(), 1_000_000);
        offers.payOut(payout);

        staking.setPaused(false);
        vm.prank(stranger);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(staking)), 1_000_000);
        assertEq(staking.lastSourceTag(), offers.SOURCE_TAG());
        assertEq(usdc.balanceOf(address(offers)), 0);
    }

    function test_revenue_push_refuses_a_staking_contract_that_pulls_short() public {
        bytes32 id = placed(SLOT, 10_000_000);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        staking.setShortBy(1);
        vm.expectRevert(RegentOffers.AmountNotReceived.selector);
        offers.pushRevenue();
        assertEq(offers.revenueOwed(), 1_000_000);
    }

    // ---------------------------------------------------------- venue admin

    function test_only_the_owner_adds_venues_and_only_its_admin_changes_one() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        offers.addVenue(keccak256("other"), admin, operator, payout, MINIMUM, LENGTH);

        vm.expectRevert(RegentOffers.VenueExists.selector);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, payout, MINIMUM, LENGTH);

        vm.startPrank(stranger);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(VENUE, stranger);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setPayout(VENUE, stranger);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setTerms(VENUE, 1, 1);
        vm.stopPrank();

        vm.expectRevert(RegentOffers.ContractIsParty.selector);
        vm.prank(admin);
        offers.setPayout(VENUE, address(offers));
    }

    function test_new_terms_leave_bids_already_made_alone() public {
        bytes32 id = placed(SLOT, 10_000_000);
        vm.prank(admin);
        offers.setTerms(VENUE, 5_000_000, 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(RegentOffers.NotFinished.selector);
        offers.finish(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        offers.finish(id);
    }

    function test_the_owner_replaces_a_lost_admin() public {
        address fresh = makeAddr("fresh admin");
        vm.prank(owner);
        offers.setVenueAdmin(VENUE, fresh);
        vm.prank(fresh);
        offers.setOperator(VENUE, fresh);
        (, address op,,,) = offers.venues(VENUE);
        assertEq(op, fresh);
    }

    function test_constructor_refuses_a_share_over_the_whole() public {
        vm.expectRevert(RegentOffers.ShareTooLarge.selector);
        new RegentOffers(usdc, staking, 10_001, owner);
    }
}
