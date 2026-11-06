// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {RegentOffers, IRegentRevenueStaking} from "../src/RegentOffers.sol";
import {OffersTestUSDC, OffersTestStaking, OffersTestWallet} from "./OffersTestTokens.sol";

/// @notice Shared set-up: a venue, a second venue to add, a bidder key and a way to sign a bid's
///         USDC authorization.
abstract contract OffersSetUp is Test {
    OffersTestUSDC internal usdc;
    OffersTestStaking internal staking;
    RegentOffers internal offers;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("venue admin");
    address internal operator = makeAddr("operator");
    address internal moderator = makeAddr("moderator");
    address internal payout = makeAddr("payout");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant OTHER = keccak256("second.site");
    address internal admin2 = makeAddr("venue admin 2");
    address internal operator2 = makeAddr("operator 2");
    address internal moderator2 = makeAddr("moderator 2");
    address internal payout2 = makeAddr("payout 2");

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
        offers.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);
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

    function addOther() internal {
        vm.prank(owner);
        offers.addVenue(OTHER, admin2, operator2, moderator2, payout2, MINIMUM, LENGTH);
    }

    /// @dev A bid's getter answer is the struct's own encoding, so it decodes straight into one.
    function record(bytes32 id) internal view returns (RegentOffers.Bid memory) {
        (bool ok, bytes memory answer) = address(offers).staticcall(abi.encodeCall(offers.bids, (id)));
        require(ok, "bids read failed");
        return abi.decode(answer, (RegentOffers.Bid));
    }

    function status(bytes32 id) internal view returns (RegentOffers.Status) {
        return record(id).status;
    }

    function startsAt(bytes32 id) internal view returns (uint64) {
        return record(id).startsAt;
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
        assertEq(record(id).bidder, address(wallet));
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
        t.placeBy = uint64(vm.getBlockTimestamp() + offers.MAX_WAIT() + 1);
        signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.PlaceByTooFar.selector);
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

    /// A bid can wait at most MAX_WAIT for the operator. A signature the site chose not to use,
    /// submitted by a stranger, comes back to its bidder by then without the operator.
    function test_a_bid_waits_at_most_max_wait_then_anyone_hands_it_back() public {
        RegentOffers.Terms memory t = terms(SLOT, 100_000_000);
        t.placeBy = uint64(vm.getBlockTimestamp() + offers.MAX_WAIT());
        bytes memory signature = sign(bidderKey, bidder, t);
        vm.prank(stranger);
        bytes32 id = offers.bid(t, bidder, 0, vm.getBlockTimestamp() + 10 minutes, signature);

        vm.warp(vm.getBlockTimestamp() + offers.MAX_WAIT() - 1);
        vm.expectRevert(RegentOffers.PlaceByNotPassed.selector);
        offers.withdraw(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        offers.withdraw(id);
        assertEq(offers.owed(bidder), 100_000_000);
    }

    /// The contract is never a bidder, and a token that delivers less than the bid is refused.
    function test_the_contract_is_never_a_bidder_and_a_short_delivery_is_refused() public {
        RegentOffers.Terms memory t = terms(SLOT, 10_000_000);
        vm.expectRevert(RegentOffers.ContractIsParty.selector);
        offers.bid(t, address(offers), 0, vm.getBlockTimestamp() + 10 minutes, "");

        usdc.setShortBy(1);
        bytes memory signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.AmountNotReceived.selector);
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

    function test_only_the_operator_places_and_returns() public {
        bytes32 id = bidOn(SLOT, MINIMUM);
        vm.startPrank(moderator);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(id);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(id);
        vm.stopPrank();
    }

    /// A removal pays the whole bid, so the key that places can never remove.
    function test_only_the_moderator_removes() public {
        bytes32 id = placed(SLOT, MINIMUM);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        vm.prank(operator);
        offers.remove(id);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        vm.prank(stranger);
        offers.remove(id);
        vm.prank(moderator);
        offers.remove(id);
    }

    function test_the_moderator_is_never_the_operator() public {
        vm.startPrank(owner);
        vm.expectRevert(RegentOffers.ModeratorIsOperator.selector);
        offers.addVenue(keccak256("other"), admin, operator, operator, payout, MINIMUM, LENGTH);
        vm.expectRevert(RegentOffers.ModeratorIsOperator.selector);
        offers.setModerator(VENUE, operator);
        vm.stopPrank();

        vm.expectRevert(RegentOffers.ModeratorIsOperator.selector);
        vm.prank(admin);
        offers.setOperator(VENUE, moderator);
    }

    function test_only_the_owner_sets_the_moderator() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        vm.prank(admin);
        offers.setModerator(VENUE, admin);

        address fresh = makeAddr("fresh moderator");
        vm.prank(owner);
        offers.setModerator(VENUE, fresh);
        (,, address mod,,,) = offers.venues(VENUE);
        assertEq(mod, fresh);
    }

    /// The most a stolen operator key can charge: every slot shows one placement at a time, and a
    /// bid it replaces pays only the time it showed. Over any stretch, what is paid from a slot is
    /// at most what its placements showed, never more than the bids that ran their whole length.
    function testFuzz_a_stolen_operator_key_charges_only_time_shown(uint8 rounds, uint32 gap) public {
        rounds = uint8(bound(rounds, 1, 12));
        gap = uint32(bound(gap, 0, LENGTH));
        uint256 shownInAll;
        uint64 start = uint64(vm.getBlockTimestamp());
        for (uint256 i; i < rounds; ++i) {
            bytes32 id = bidOn(SLOT, 10_000_000);
            vm.prank(operator);
            offers.place(id);
            vm.warp(vm.getBlockTimestamp() + gap);
        }
        shownInAll = vm.getBlockTimestamp() - start;
        uint256 paid = offers.owed(payout) + offers.revenueOwed();
        // Each replaced placement pays its share of shown time; the last one is still showing.
        assertLe(paid, (uint256(10_000_000) * shownInAll) / LENGTH);
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

    /// Placing every held bid of a slot at one moment charges nothing: each is replaced before any
    /// time has shown. This holds for replacing only; a removal pays the whole bid however long it
    /// showed, which is why only the moderator, never the operator, removes.
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

    // ---------------------------------------------------------- wrong states

    /// Every step is refused for a bid that is not in the one state it applies to, and refusals
    /// move nothing.
    function test_every_step_is_refused_in_every_wrong_state() public {
        bytes32 unknown = keccak256("no such bid");
        bytes32 waiting = bidOn(SLOT, 10_000_000);
        bytes32 showing = placed(keccak256("slot 2"), 10_000_000);
        bytes32 returned = bidOn(keccak256("slot 3"), 10_000_000);
        vm.prank(operator);
        offers.returnBid(returned);
        bytes32 removed = placed(keccak256("slot 4"), 10_000_000);
        vm.prank(moderator);
        offers.remove(removed);
        uint256 payoutOwed = offers.owed(payout);
        uint256 bidderOwed = offers.owed(bidder);
        uint256 committed = offers.totalCommitted();

        vm.warp(vm.getBlockTimestamp() + 30 minutes); // before every placeBy and every end time

        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.finish(unknown);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.finish(waiting);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.finish(returned);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.finish(removed);

        vm.startPrank(moderator);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(unknown);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(waiting);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(returned);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(removed);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(unknown);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(showing);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(returned);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(removed);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.place(unknown);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.place(returned);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.place(removed);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + LENGTH); // after every placeBy and end time
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.withdraw(unknown);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.withdraw(showing);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.withdraw(returned);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.withdraw(removed);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.finish(waiting);

        assertEq(offers.owed(payout), payoutOwed);
        assertEq(offers.owed(bidder), bidderOwed);
        assertEq(offers.totalCommitted(), committed);
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
        vm.prank(moderator);
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

    /// What is owed to an address USDC has blocked stays owed to it: a new payout wallet does not
    /// take it and nothing else can move it. It is paid when USDC pays that address again.
    function test_money_owed_to_a_blocked_payout_wallet_waits_for_usdc() public {
        bytes32 id = placed(SLOT, 100_000_000);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        usdc.setBlocked(payout, true);

        address fresh = makeAddr("fresh payout");
        vm.prank(admin);
        offers.setPayout(VENUE, fresh);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        offers.payOut(payout);
        assertEq(offers.owed(payout), 90_000_000);
        assertEq(offers.owed(fresh), 0);

        usdc.setBlocked(payout, false);
        offers.payOut(payout);
        assertEq(usdc.balanceOf(payout), 90_000_000);
    }

    /// While staking refuses deposits its share waits in the contract, and everyone else is paid.
    function test_the_staking_share_waits_while_staking_refuses_it() public {
        bytes32 id = placed(SLOT, 100_000_000);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        usdc.setBlocked(address(staking), true);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        offers.pushRevenue();
        offers.payOut(payout);
        assertEq(usdc.balanceOf(address(offers)), offers.revenueOwed());
        assertEq(offers.revenueOwed(), 10_000_000);

        usdc.setBlocked(address(staking), false);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(staking)), 10_000_000);
    }

    /// USDC sent to the contract other than through a bid is in no record: every account is paid
    /// in full and it is all that remains.
    function test_usdc_sent_directly_is_in_no_record() public {
        usdc.mint(address(offers), 7_000_000);
        bytes32 id = placed(SLOT, 10_000_000);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        offers.payOut(payout);
        offers.pushRevenue();
        assertEq(offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed(), 0);
        assertEq(usdc.balanceOf(address(offers)), 7_000_000);
    }

    // ---------------------------------------------------------- payout wallets

    /// Each bid pays the payout wallet named when it was made. A new wallet is paid only for bids
    /// made after it, whether they are showing or waiting when it changes.
    function test_a_new_payout_wallet_is_paid_only_for_bids_made_after_it() public {
        bytes32 showing = placed(SLOT, 10_000_000);
        bytes32 waiting = bidOn(keccak256("slot 2"), 20_000_000);
        address fresh = makeAddr("fresh payout");
        vm.prank(admin);
        offers.setPayout(VENUE, fresh);
        bytes32 later = bidOn(keccak256("slot 3"), 40_000_000);
        assertEq(record(waiting).payout, payout);
        assertEq(record(later).payout, fresh);

        vm.startPrank(operator);
        offers.place(waiting);
        offers.place(later);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(showing);
        offers.finish(waiting);
        offers.finish(later);
        assertEq(offers.owed(payout), 27_000_000);
        assertEq(offers.owed(fresh), 36_000_000);
    }

    /// The contract itself, the USDC token (which USDC never pays) and the staking contract (whose
    /// share is pushed, never paid out) are never payout wallets.
    function test_neither_the_contract_nor_usdc_nor_staking_is_a_payout_wallet() public {
        address[3] memory refused = [address(offers), address(usdc), address(staking)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(RegentOffers.ContractIsParty.selector);
            offers.setPayout(VENUE, refused[i]);
            vm.prank(owner);
            vm.expectRevert(RegentOffers.ContractIsParty.selector);
            offers.addVenue(OTHER, admin2, operator2, moderator2, refused[i], MINIMUM, LENGTH);
        }
        vm.prank(owner);
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.addVenue(OTHER, admin2, operator2, moderator2, address(0), MINIMUM, LENGTH);
    }

    // ---------------------------------------------------------- venue admin

    function test_only_the_owner_adds_venues_and_only_its_admin_changes_one() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        offers.addVenue(keccak256("other"), admin, operator, moderator, payout, MINIMUM, LENGTH);

        vm.expectRevert(RegentOffers.VenueExists.selector);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);

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

    /// New terms bind new bids: the old length is refused, the new minimum applies.
    function test_new_terms_bind_new_bids() public {
        vm.prank(admin);
        offers.setTerms(VENUE, 5_000_000, 24 hours);

        RegentOffers.Terms memory t = terms(SLOT, 10_000_000); // still the old 72 h
        bytes memory signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.LengthMismatch.selector);
        submit(t, signature);

        t = terms(SLOT, 4_999_999);
        t.length = 24 hours;
        signature = sign(bidderKey, bidder, t);
        vm.expectRevert(RegentOffers.BelowMinimum.selector);
        submit(t, signature);

        t = terms(SLOT, 5_000_000);
        t.length = 24 hours;
        bytes32 id = submit(t, sign(bidderKey, bidder, t));
        vm.prank(operator);
        offers.place(id);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        offers.finish(id);
        assertEq(offers.owed(payout), 4_500_000);
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
        (, address op,,,,) = offers.venues(VENUE);
        assertEq(op, fresh);
    }

    // ---------------------------------------------------------- two venues

    /// One site's keys and slots are separate from another's, even where slot ids are the same.
    function test_two_venues_are_separate() public {
        addOther();
        bytes32 mine = bidOn(SLOT, 10_000_000);
        RegentOffers.Terms memory t = terms(SLOT, 30_000_000);
        t.venue = OTHER;
        bytes32 theirs = submit(t, sign(bidderKey, bidder, t));

        vm.startPrank(operator);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(theirs);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(theirs);
        offers.place(mine);
        vm.stopPrank();
        vm.startPrank(admin);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setPayout(OTHER, admin);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(OTHER, admin);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setTerms(OTHER, 1, 1);
        vm.stopPrank();

        vm.prank(operator2);
        offers.place(theirs); // does not replace `mine`
        assertEq(offers.live(VENUE, SLOT), mine);
        assertEq(offers.live(OTHER, SLOT), theirs);
        vm.prank(moderator);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(theirs);

        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(mine);
        offers.finish(theirs);
        assertEq(offers.owed(payout), 9_000_000);
        assertEq(offers.owed(payout2), 27_000_000);
        assertEq(offers.revenueOwed(), 4_000_000);
    }

    /// A signature for one site's slot cannot fund the same slot on another site.
    function test_a_signature_is_bound_to_its_venue() public {
        addOther();
        RegentOffers.Terms memory t = terms(SLOT, 10_000_000);
        bytes memory signature = sign(bidderKey, bidder, t);
        t.venue = OTHER;
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        submit(t, signature);
    }

    // ---------------------------------------------------------- re-entry

    /// A staking contract that calls back into every money function during its deposit is refused
    /// each time, and the books stay exact.
    function test_staking_cannot_reenter() public {
        ReenteringStaking evil = new ReenteringStaking(usdc);
        offers = new RegentOffers(usdc, evil, PROTOCOL_BPS, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);
        bytes32 id = placed(SLOT, 100_000_000);
        bytes32 two = bidOn(keccak256("slot 2"), 50_000_000);
        vm.prank(operator);
        offers.returnBid(two);
        evil.aim(offers, bidder, two);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);
        offers.pushRevenue();
        assertEq(evil.refused(), 3);
        assertEq(offers.owed(bidder), 50_000_000);
        assertEq(usdc.balanceOf(address(offers)), offers.totalOwed());
        assertEq(usdc.balanceOf(address(evil)), 10_000_000);
    }

    /// A token that calls back into the market while it moves money, as an upgraded USDC with
    /// transfer hooks could, is refused on every path: funding a bid, paying out and pushing revenue.
    function test_a_token_hook_cannot_reenter() public {
        ReenteringUSDC evil = new ReenteringUSDC();
        usdc = evil;
        staking = new OffersTestStaking(evil);
        offers = new RegentOffers(evil, staking, PROTOCOL_BPS, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, MINIMUM, LENGTH);
        evil.mint(bidder, 1_000_000_000);
        bytes32 id = placed(SLOT, 100_000_000);
        bytes32 two = bidOn(keccak256("slot 2"), 50_000_000);
        vm.prank(operator);
        offers.returnBid(two);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(id);

        evil.aim(offers, bidder, id);
        bidOn(keccak256("slot 3"), 5_000_000);
        offers.payOut(bidder);
        offers.pushRevenue();
        assertEq(evil.refused(), 9);
        assertEq(offers.owed(bidder), 0);
        assertEq(usdc.balanceOf(address(offers)), offers.totalCommitted() + offers.totalOwed());
    }

    /// USDC asks a contract wallet about its signature with a read-only call, so a wallet that
    /// tries to take money while it is asked cannot.
    function test_a_contract_wallet_asked_about_its_signature_cannot_reenter() public {
        bytes32 first = bidOn(SLOT, 10_000_000);
        vm.prank(operator);
        offers.returnBid(first);
        ReenteringWallet wallet = new ReenteringWallet(bidder, offers, bidder);
        usdc.mint(address(wallet), 10_000_000);
        RegentOffers.Terms memory t = terms(keccak256("slot 2"), MINIMUM);
        bytes memory signature = sign(bidderKey, address(wallet), t);
        bytes32 id = offers.bid(t, address(wallet), 0, vm.getBlockTimestamp() + 10 minutes, signature);
        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Held));
        assertEq(offers.owed(bidder), 10_000_000);
        assertEq(usdc.balanceOf(bidder), 1_000_000_000_000 - 10_000_000);
    }

    function test_constructor_refuses_a_share_over_the_whole() public {
        vm.expectRevert(RegentOffers.ShareTooLarge.selector);
        new RegentOffers(usdc, staking, 10_001, owner);
    }
}

/// @notice Pulls its deposit, then tries to re-enter RegentOffers three ways.
contract ReenteringStaking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    RegentOffers internal target;
    address internal victim;
    bytes32 internal heldId;
    uint256 public refused;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function aim(RegentOffers target_, address victim_, bytes32 heldId_) external {
        target = target_;
        victim = victim_;
        heldId = heldId_;
    }

    function depositUSDC(uint256 amount, bytes32, bytes32) external returns (uint256) {
        require(usdc.transferFrom(msg.sender, address(this), amount), "PULL_FAILED");
        _count(address(target), abi.encodeCall(RegentOffers.payOut, (victim)));
        _count(address(target), abi.encodeCall(RegentOffers.pushRevenue, ()));
        _count(address(target), abi.encodeCall(RegentOffers.withdraw, (heldId)));
        return amount;
    }

    function _count(address to, bytes memory data) internal {
        (bool ok, bytes memory why) = to.call(data);
        if (!ok && bytes4(why) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector) ++refused;
    }
}

/// @notice A USDC stand-in that, once aimed, calls back into the market on every transfer.
contract ReenteringUSDC is OffersTestUSDC {
    RegentOffers internal target;
    address internal victim;
    bytes32 internal placedId;
    uint256 public refused;

    function aim(RegentOffers target_, address victim_, bytes32 placedId_) external {
        target = target_;
        victim = victim_;
        placedId = placedId_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) == address(0)) return;
        _count(abi.encodeCall(RegentOffers.payOut, (victim)));
        _count(abi.encodeCall(RegentOffers.pushRevenue, ()));
        _count(abi.encodeCall(RegentOffers.finish, (placedId)));
    }

    function _count(bytes memory data) internal {
        (bool ok, bytes memory why) = address(target).call(data);
        if (!ok && bytes4(why) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector) ++refused;
    }
}

/// @notice A contract wallet that accepts its owner key's signatures and, while asked, tries to
///         pay out another account's money.
contract ReenteringWallet {
    address internal immutable signer;
    RegentOffers internal immutable target;
    address internal immutable victim;

    constructor(address signer_, RegentOffers target_, address victim_) {
        signer = signer_;
        target = target_;
        victim = victim_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external returns (bytes4) {
        try target.payOut(victim) {
            return bytes4(0xffffffff);
        } catch {}
        return SignatureChecker.isValidSignatureNow(signer, digest, signature) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
