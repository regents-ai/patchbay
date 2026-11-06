// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RegentOffers} from "../src/RegentOffers.sol";
import {OffersSetUp} from "./RegentOffers.t.sol";

/// @title RegentOffersKeysTest
/// @notice What each key can do if it is stolen. No key can send a bid's money anywhere but back
///         to its bidder, to the payout wallet named when the bid was made, or to staking; no key
///         can touch money already owed; and a replaced key stops working at once.
contract RegentOffersKeysTest is OffersSetUp {
    address internal thief = makeAddr("thief");
    address internal thiefOperator = makeAddr("thief operator");
    address internal thiefModerator = makeAddr("thief moderator");

    // ------------------------------------------------------------ operator

    /// The operator places and returns but never removes, so on its own it cannot charge a bid it
    /// never showed: what it places and replaces at once costs nothing.
    function test_a_stolen_operator_key_cannot_charge_a_bid_it_never_showed() public {
        bytes32 id = bidOn(SLOT, 100_000_000);
        bytes32 next = bidOn(SLOT, 100_000_000);
        vm.startPrank(operator);
        offers.place(id);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(id);
        offers.place(next);
        vm.stopPrank();
        assertEq(offers.owed(bidder), 100_000_000);
        assertEq(offers.owed(payout), 0);
        assertEq(offers.revenueOwed(), 0);
    }

    /// The operator key sends nothing to itself, cannot change the payout wallet or the
    /// moderator, and cannot place a bid past its placeBy.
    function test_a_stolen_operator_key_gains_nothing_itself() public {
        bytes32 a = bidOn(SLOT, 100_000_000);
        bytes32 b = bidOn(keccak256("slot 2"), 50_000_000);
        bytes32 late = bidOn(keccak256("slot 3"), 25_000_000);
        vm.startPrank(operator);
        offers.place(a);
        offers.returnBid(b);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setPayout(VENUE, operator);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(VENUE, thief);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        offers.setModerator(VENUE, thief);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(operator);
        vm.expectRevert(RegentOffers.PlaceByPassed.selector);
        offers.place(late);
        offers.withdraw(late);
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(a);
        offers.payOut(payout);
        offers.payOut(bidder);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(operator), 0);
        assertEq(usdc.balanceOf(payout), 90_000_000);
        assertEq(usdc.balanceOf(address(staking)), 10_000_000);
        assertEq(usdc.balanceOf(address(offers)), 0);
    }

    // ------------------------------------------------------------ moderator

    /// The moderator only removes showing bids, and what it removes is paid to the site and
    /// staking, never to the moderator.
    function test_a_stolen_moderator_key_reaches_only_showing_bids_and_pays_the_site() public {
        bytes32 waiting = bidOn(SLOT, 100_000_000);
        bytes32 showing = placed(keccak256("slot 2"), 200_000_000);
        vm.startPrank(moderator);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(waiting);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(waiting);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(waiting);
        offers.remove(showing);
        vm.stopPrank();
        assertEq(offers.owed(moderator), 0);
        assertEq(offers.owed(payout), 180_000_000);
        assertEq(offers.revenueOwed(), 20_000_000);
        assertEq(uint8(status(waiting)), uint8(RegentOffers.Status.Held));
    }

    /// Sean's rule (6 Nov 2026, 4 b): a removal pays the whole bid. With both the placing and the
    /// removing key, a bid shown for no time at all is charged in full; the money goes to the
    /// payout wallet named when the bid was made and to staking, never to whoever holds the keys.
    function test_placing_and_removing_keys_together_charge_a_bid_in_full_to_the_site() public {
        bytes32 id = bidOn(SLOT, 100_000_000);
        vm.prank(operator);
        offers.place(id);
        vm.prank(moderator);
        offers.remove(id);
        assertEq(offers.owed(bidder), 0);
        assertEq(offers.owed(payout), 90_000_000);
        assertEq(offers.revenueOwed(), 10_000_000);
    }

    // ------------------------------------------------------------ venue admin

    /// A stolen venue admin key can name its own operator and payout wallet, but bids made before
    /// that keep paying the site's wallet, and it can neither remove nor name the moderator.
    function test_a_stolen_admin_key_takes_nothing_already_bid() public {
        bytes32 waiting = bidOn(SLOT, 100_000_000);
        bytes32 showing = placed(keccak256("slot 2"), 200_000_000);

        vm.startPrank(admin);
        offers.setOperator(VENUE, thief);
        offers.setPayout(VENUE, thief);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        offers.setModerator(VENUE, thiefModerator);
        vm.stopPrank();

        vm.startPrank(thief);
        offers.place(waiting);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(waiting);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(showing);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + LENGTH);
        offers.finish(waiting);
        offers.finish(showing);

        assertEq(offers.owed(thief), 0);
        assertEq(offers.owed(payout), 270_000_000);
        vm.expectRevert(RegentOffers.NothingOwed.selector);
        offers.payOut(thief);
    }

    // ------------------------------------------------------------ owner

    /// A stolen owner key can hand every venue to the thief, moderator included. It can then make
    /// bids already made pay in full, but only to the payout wallet each was made under and to
    /// staking: the thief takes nothing on any venue.
    function test_a_stolen_owner_key_takes_nothing_already_bid_on_any_venue() public {
        addOther();
        bytes32 one = bidOn(SLOT, 100_000_000);
        RegentOffers.Terms memory t = terms(SLOT, 300_000_000);
        t.venue = OTHER;
        bytes32 two = submit(t, sign(bidderKey, bidder, t));

        bytes32[2] memory venueIds = [VENUE, OTHER];
        bytes32[2] memory ids = [one, two];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(owner);
            offers.setVenueAdmin(venueIds[i], thief);
            offers.setModerator(venueIds[i], thiefModerator);
            vm.stopPrank();
            vm.startPrank(thief);
            offers.setOperator(venueIds[i], thiefOperator);
            offers.setPayout(venueIds[i], thief);
            vm.stopPrank();
            vm.prank(thiefOperator);
            offers.place(ids[i]);
            vm.prank(thiefModerator);
            offers.remove(ids[i]);
        }
        assertEq(offers.owed(thief), 0);
        assertEq(offers.owed(payout), 90_000_000);
        assertEq(offers.owed(payout2), 270_000_000);
        assertEq(offers.revenueOwed(), 40_000_000);
    }

    /// No key reaches money already owed or the staking share, and pausing stops neither.
    function test_no_key_reaches_money_already_owed() public {
        bytes32 first = placed(SLOT, 100_000_000);
        vm.warp(vm.getBlockTimestamp() + 36 hours);
        bytes32 second = bidOn(SLOT, 100_000_000);
        vm.prank(operator);
        offers.place(second); // first: half paid, half owed back
        assertEq(uint8(status(first)), uint8(RegentOffers.Status.Ended));
        assertEq(offers.owed(bidder), 50_000_000);
        assertEq(offers.owed(payout), 45_000_000);
        assertEq(offers.revenueOwed(), 5_000_000);

        vm.startPrank(owner);
        offers.setVenueAdmin(VENUE, thief);
        offers.setModerator(VENUE, thiefModerator);
        offers.setPaused(true);
        vm.stopPrank();
        vm.startPrank(thief);
        offers.setOperator(VENUE, thiefOperator);
        offers.setPayout(VENUE, thief);
        vm.stopPrank();
        vm.prank(thiefModerator);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(first);
        vm.startPrank(thiefOperator);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(first);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.place(first);
        vm.stopPrank();

        offers.payOut(bidder);
        offers.payOut(payout);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(payout), 45_000_000);
        assertEq(usdc.balanceOf(address(staking)), 5_000_000);
        assertEq(offers.owed(thief), 0);
    }

    // ------------------------------------------------------------ replaced keys

    /// A replaced operator key can do nothing from that moment; the new one can.
    function test_a_replaced_operator_key_is_dead() public {
        bytes32 waiting = bidOn(SLOT, 10_000_000);
        bytes32 other = bidOn(keccak256("slot 2"), 10_000_000);
        bytes32 showing = placed(keccak256("slot 3"), 10_000_000);
        address fresh = makeAddr("new operator");
        vm.prank(admin);
        offers.setOperator(VENUE, fresh);

        vm.startPrank(operator);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(waiting);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(waiting);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(showing);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(VENUE, operator);
        vm.stopPrank();

        vm.startPrank(fresh);
        offers.place(waiting);
        offers.returnBid(other);
        vm.stopPrank();
    }

    /// A replaced moderator key can remove nothing from that moment; the new one can.
    function test_a_replaced_moderator_key_is_dead() public {
        bytes32 showing = placed(SLOT, 10_000_000);
        address fresh = makeAddr("new moderator");
        vm.prank(owner);
        offers.setModerator(VENUE, fresh);
        vm.prank(moderator);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(showing);
        vm.prank(fresh);
        offers.remove(showing);
    }
}
