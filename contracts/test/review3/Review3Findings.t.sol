// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RegentOffers} from "../../src/RegentOffers.sol";
import {Review3Base, R3USDC} from "./Review3Base.sol";

/// @title Review3FindingsTest
/// @notice Review 3 (commit 150525fd). Each test here PASSES, and by passing shows something a
///         reasonable owner, bidder or venue would not expect. None of them takes USDC out of the
///         contract to a wallet the rules do not name.
contract Review3FindingsTest is Review3Base {
    // ------------------------------------------------------------------ F1
    /// A pause, the owner's only switch, also switches off the only clean-up that refunds a
    /// bidder. The header says a wrong placement "is cleaned up by replacing it with another bid,
    /// never by removal". Replacing needs a held bid on that slot; with bids paused none can be
    /// made, so the wrong placement keeps charging its bidder until the pause is lifted.
    function test_R3_F1_a_pause_blocks_the_only_cleanup_that_refunds_the_bidder() public {
        bytes32 id = _bid(bidder, SLOT, 72_000_000);
        vm.prank(operator); // the operator key is stolen and shows the bid
        offers.place(id);

        // The owner reacts with the one switch it has, and the admin replaces the stolen key.
        vm.prank(owner);
        offers.setPaused(true);
        address newOperator = makeAddr("r3 new operator");
        vm.prank(admin);
        offers.setOperator(VENUE, newOperator);
        vm.warp(_now() + 1 hours);

        // The documented clean-up: the site's own one-USDC bid replaces the wrong placement.
        (bool ok,, bytes memory why) = _enter(site, VENUE, SLOT, MINIMUM, LENGTH, uint64(_now() + 1 hours));
        assertFalse(ok, "no clean-up bid can be made while paused");
        assertEq(bytes4(why), RegentOffers.BidsPaused.selector);

        // What is left while paused: remove it (whole bid paid) or let it run (whole bid paid).
        uint256 snap = vm.snapshotState();
        vm.prank(moderator);
        offers.remove(id);
        assertEq(offers.owed(bidder), 0, "removal: the bidder gets nothing back");
        assertEq(offers.owed(payout) + offers.revenueOwed(), 72_000_000);
        vm.revertToState(snap);

        vm.warp(_now() + LENGTH);
        offers.finish(id);
        assertEq(offers.owed(bidder), 0, "waiting: the bidder gets nothing back");
        vm.revertToState(snap);

        // Only by lifting the pause, which lets everyone bid again, is the bidder refunded.
        vm.prank(owner);
        offers.setPaused(false);
        bytes32 own = _bid(site, SLOT, MINIMUM);
        vm.prank(newOperator);
        offers.place(own);
        assertEq(offers.owed(bidder), 71_000_000, "one hour of 72 paid, 71 back");
        // And the clean-up bid is now showing itself: it cannot be taken down without paying.
        assertEq(offers.live(VENUE, SLOT), own);
        vm.prank(newOperator);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(own);
    }

    // ------------------------------------------------------------------ F2
    /// The venue admin can refuse the owner's choice of moderator: it names that address as the
    /// operator first, and the owner's call fails. The old moderator keeps removing meanwhile.
    /// The owner gets out only by replacing the admin, having the new admin move the operator,
    /// and then naming the moderator: three calls from two keys.
    function test_R3_F2_the_admin_can_block_the_owners_choice_of_moderator() public {
        address newModerator = makeAddr("r3 new moderator");
        bytes32 showing = _placed(bidder, SLOT, 50_000_000);

        vm.prank(admin); // lands just before the owner's call
        offers.setOperator(VENUE, newModerator);
        vm.prank(owner);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setModerator(VENUE, newModerator);

        // The moderator the owner wanted gone still removes, charging the bidder in full.
        vm.prank(moderator);
        offers.remove(showing);
        assertEq(offers.owed(bidder), 0);

        address freshAdmin = makeAddr("r3 fresh admin");
        vm.startPrank(owner);
        offers.setVenueAdmin(VENUE, freshAdmin);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setModerator(VENUE, newModerator); // still blocked: the operator is unchanged
        vm.stopPrank();
        vm.prank(freshAdmin);
        offers.setOperator(VENUE, makeAddr("r3 fresh operator"));
        vm.prank(owner);
        offers.setModerator(VENUE, newModerator);
        assertEq(_venueOf(VENUE).moderator, newModerator);
    }

    // ------------------------------------------------------------------ F3
    /// Nothing keeps the moderator apart from the payout wallet. Where they are one address, the
    /// key that removes is the key that is paid: it takes 90% of any showing bid at once. The
    /// suite's own comment says a removal is paid "never to the moderator"; the code does not
    /// enforce that, in either order of setting.
    function test_R3_F3_the_remover_may_be_the_wallet_that_is_paid() public {
        vm.prank(owner);
        offers.setPayout(VENUE, moderator); // accepted
        bytes32 id = _placed(bidder, SLOT, 100_000_000);
        vm.prank(moderator);
        offers.remove(id); // zero seconds shown
        offers.payOut(moderator);
        assertEq(usdc.balanceOf(moderator), 90_000_000, "the remover was paid 90% of what it removed");
        assertEq(offers.owed(bidder), 0);

        // The other order, and at the venue's creation, are accepted too.
        vm.startPrank(owner);
        offers.setPayout(VENUE, payout);
        offers.setModerator(VENUE, payout);
        offers.addVenue(keccak256("second.site"), admin, operator, moderator, moderator, MINIMUM, LENGTH);
        vm.stopPrank();
        assertEq(_venueOf(VENUE).moderator, _venueOf(VENUE).payout);
    }

    // ------------------------------------------------------------------ F4
    /// A stolen admin key cannot remove, but it sets the placement length. With a length of one
    /// second, a bid made at the venue's current terms is charged in full one second after it is
    /// placed: the same result as a removal, from the key the header says "can never remove".
    /// The bidder's only protection is noticing the length inside the terms it sends.
    function test_R3_F4_a_stolen_admin_key_charges_new_bids_in_full_after_one_second() public {
        vm.startPrank(admin); // stolen
        offers.setOperator(VENUE, thief);
        offers.setTerms(VENUE, MINIMUM, 1);
        vm.stopPrank();

        bytes32 id = _bid(bidder, SLOT, 100_000_000); // the site fills in the venue's current length
        vm.prank(thief);
        offers.place(id);
        vm.warp(_now() + 1);
        offers.finish(id);
        assertEq(offers.owed(bidder), 0, "whole bid charged after one second");
        assertEq(offers.owed(payout), 90_000_000);
    }

    // ------------------------------------------------------------------ F5
    /// The README gives "pause new bids" to the owner alone. The venue admin has the same power
    /// over its venue: a minimum no one can meet. A stolen admin key can use it to stop the site's
    /// own clean-up bids as well.
    function test_R3_F5_the_admin_can_stop_every_new_bid_on_its_venue() public {
        vm.prank(admin);
        offers.setTerms(VENUE, type(uint96).max, LENGTH);
        (bool ok,, bytes memory why) = _enter(bidder, VENUE, SLOT, 1_000_000_000_000, LENGTH, uint64(_now() + 1 hours));
        assertFalse(ok);
        assertEq(bytes4(why), RegentOffers.BelowMinimum.selector);
        assertFalse(offers.paused());
    }

    // ------------------------------------------------------------------ F6
    /// When USDC blocks a venue's payout wallet, the owner names a new one, but every bid already
    /// made (held or showing) goes on crediting the blocked wallet. That money can never be moved.
    /// It is documented; this measures it. The only way to save the venue's share of a held bid
    /// is for the operator to return it and the bidder to bid again.
    function test_R3_F6_a_blocked_payout_wallet_keeps_catching_bids_already_made() public {
        bytes32 held1 = _bid(bidder, SLOT, 100_000_000);
        bytes32 held2 = _bid(bidder2, keccak256("forum#2"), 200_000_000);
        usdc.setBlacklisted(payout, true);
        address fresh = makeAddr("r3 fresh payout");
        vm.prank(owner);
        offers.setPayout(VENUE, fresh);

        vm.startPrank(operator);
        offers.place(held1);
        offers.place(held2);
        vm.stopPrank();
        vm.warp(_now() + LENGTH);
        offers.finish(held1);
        offers.finish(held2);

        assertEq(offers.owed(fresh), 0, "the new wallet gets nothing of bids already made");
        assertEq(offers.owed(payout), 270_000_000, "all of it is owed to the blocked wallet");
        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, payout));
        offers.payOut(payout);
        assertEq(usdc.balanceOf(address(offers)) - offers.revenueOwed(), 270_000_000, "and stays in the contract");
    }

    // ------------------------------------------------------------------ F7
    /// If USDC blocks this contract's own address, no one can be paid or refunded and no bid can
    /// come in, yet placements keep being placed, removed and finished: bidders go on being
    /// charged in the books for money nobody can receive. Nothing in the contract can respond.
    function test_R3_F7_if_usdc_blocks_the_contract_charging_goes_on_and_nothing_can_be_paid() public {
        bytes32 showing = _placed(bidder, SLOT, 100_000_000);
        bytes32 waiting = _bid(bidder2, keccak256("forum#2"), 50_000_000);
        bytes32 back = _bid(bidder2, keccak256("forum#3"), 25_000_000);
        vm.prank(operator);
        offers.returnBid(back);

        usdc.setBlacklisted(address(offers), true);

        vm.prank(operator);
        offers.place(waiting); // still placed
        vm.prank(moderator);
        offers.remove(waiting); // still charged in full
        vm.warp(_now() + LENGTH);
        offers.finish(showing); // still charged in full

        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, address(offers)));
        offers.payOut(bidder2);
        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, address(offers)));
        offers.payOut(payout);
        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, address(offers)));
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(offers)), 175_000_000, "all of it stays");
        assertEq(offers.owed(bidder2), 25_000_000);
        assertEq(offers.owed(payout), 135_000_000);
        assertEq(offers.revenueOwed(), 15_000_000);
    }

    // ------------------------------------------------------------------ F8
    /// The protocol share rounds down on every ending, so a payment under ten base units pays
    /// REGENT staking nothing, and the admin may set a minimum that low. The sums are fractions of
    /// a cent; the point is that "10%" is a ceiling, not a floor.
    function test_R3_F8_payments_under_ten_units_pay_staking_nothing() public {
        vm.prank(admin);
        offers.setTerms(VENUE, 9, LENGTH);
        for (uint256 i; i < 50; ++i) {
            bytes32 id = _placed(bidder, bytes32(i + 1), 9);
            vm.prank(moderator);
            offers.remove(id);
        }
        assertEq(offers.revenueOwed(), 0, "staking is owed nothing of 450 units paid");
        assertEq(offers.owed(payout), 450);

        // The same on a normal bid replaced early: 2 seconds of a 1 USDC, 72 hour bid pays 7 units.
        vm.prank(admin);
        offers.setTerms(VENUE, MINIMUM, LENGTH);
        bytes32 first = _placed(bidder, SLOT, 1_000_000);
        vm.warp(_now() + 2);
        _placed(bidder2, SLOT, 1_000_000);
        assertEq(offers.owed(bidder), 999_993);
        assertEq(offers.owed(payout), 457);
        assertEq(offers.revenueOwed(), 0);
        assertEq(uint8(_status(first)), uint8(RegentOffers.Status.Ended));
    }

    // ------------------------------------------------------------------ F9
    /// "The owner must be a multi-owner Safe" is a sentence, not a check: a plain key is accepted
    /// at deployment and at every handover. Nor is the protocol share fixed at 10%: any share up
    /// to the whole payment is accepted, leaving the venue nothing.
    function test_R3_F9_the_owner_need_not_be_a_safe_and_the_share_need_not_be_ten_percent() public {
        address plainKey = makeAddr("r3 one plain key");
        assertEq(plainKey.code.length, 0);
        RegentOffers solo = new RegentOffers(usdc, staking, 10_000, plainKey);
        assertEq(solo.owner(), plainKey);
        (,,, uint256 venueShare) = solo.split(100_000_000, 0, LENGTH, LENGTH, RegentOffers.EndReason.Finished);
        assertEq(venueShare, 0, "a 100% protocol share is accepted");

        vm.prank(owner);
        offers.transferOwnership(plainKey);
        vm.prank(plainKey);
        offers.acceptOwnership();
        assertEq(offers.owner(), plainKey);
    }

    // ------------------------------------------------------------------ F10
    /// A bidder has no way out of a held bid before its placeBy, whatever changes around it. The
    /// bid is not tied to the moderator, admin or operator it was made under: the owner may
    /// replace all three afterwards and the new keys may place and remove it, charging it in full
    /// (to the wallet stored with it). A pause does not help the bidder either.
    function test_R3_F10_a_bidder_cannot_leave_a_held_bid_when_the_keys_around_it_change() public {
        bytes32 id = _bid(bidder, SLOT, 100_000_000);
        address a2 = makeAddr("r3 admin 2");
        address o2 = makeAddr("r3 operator 2");
        address m2 = makeAddr("r3 moderator 2");
        vm.startPrank(owner);
        offers.setVenueAdmin(VENUE, a2);
        offers.setModerator(VENUE, m2);
        offers.setPaused(true);
        vm.stopPrank();
        vm.prank(a2);
        offers.setOperator(VENUE, o2);

        vm.prank(bidder);
        vm.expectRevert(RegentOffers.PlaceByNotPassed.selector);
        offers.withdraw(id);
        vm.prank(bidder);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(id);

        vm.prank(o2);
        offers.place(id);
        vm.prank(m2);
        offers.remove(id);
        assertEq(offers.owed(bidder), 0);
        assertEq(offers.owed(payout), 90_000_000);
    }
}
