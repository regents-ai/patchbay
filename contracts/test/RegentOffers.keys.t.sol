// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RegentOffers} from "../src/RegentOffers.sol";
import {OffersSetUp} from "./RegentOffers.t.sol";
import {OffersTestUSDC} from "./OffersTestTokens.sol";

/// @title RegentOffersKeysTest
/// @notice What each key can do if it is stolen. Holding a bidder's signature makes only the bid
///         it signed. No key can send a bid's money anywhere but back to its bidder, to the payout wallet named when the bid was made, or to staking; no key
///         can touch money already owed; and a replaced key stops working at once.
contract RegentOffersKeysTest is OffersSetUp {
    address internal thief = makeAddr("thief");
    address internal thiefOperator = makeAddr("thief operator");
    address internal thiefModerator = makeAddr("thief moderator");

    // ------------------------------------------------- the site's signatures

    /// Whoever holds a bidder's signature, such as the site's server, can make only the bid the
    /// bidder signed: another amount, slot, lane, wording, place-by time, venue or bidder is
    /// refused by USDC, and the bid made is the bidder's, with the bidder's money.
    function test_a_stolen_site_key_makes_only_the_bids_that_were_signed() public {
        addOther();
        RegentOffers.Terms memory t = terms(SLOT, 50_000_000);
        bytes memory signature = sign(bidder, t);
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        usdc.mint(thief, 100_000_000);

        RegentOffers.Terms[6] memory changed;
        for (uint256 i; i < 6; ++i) {
            changed[i] =
                RegentOffers.Terms(t.venue, t.slot, t.lane, t.wordingHash, t.amount, t.length, t.placeBy, t.salt);
        }
        changed[0].amount = 100_000_000;
        changed[1].slot = keccak256("the thief's slot");
        changed[2].lane = 1;
        changed[3].wordingHash = keccak256("the thief's wording");
        changed[4].placeBy = t.placeBy + 1 hours;
        changed[5].venue = OTHER;
        vm.startPrank(relayer);
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(OffersTestUSDC.InvalidSignature.selector);
            offers.bid(changed[i], bidder, 0, validBefore, signature);
        }
        vm.expectRevert(OffersTestUSDC.InvalidSignature.selector);
        offers.bid(t, thief, 0, validBefore, signature);
        assertEq(offers.totalCommitted(), 0);

        bytes32 id = offers.bid(t, bidder, 0, validBefore, signature);
        vm.stopPrank();
        assertEq(record(id).bidder, bidder);
        assertEq(record(id).amount, 50_000_000);
        assertEq(usdc.balanceOf(thief), 100_000_000);
        assertEq(offers.totalCommitted(), 50_000_000);
    }

    /// Signatures a stolen site key holds but never submitted die with their time window, and one
    /// it does submit late in its window still comes back to its bidder by its place-by time.
    function test_signatures_a_stolen_site_key_holds_end_with_their_window() public {
        RegentOffers.Terms memory held = terms(SLOT, 20_000_000);
        RegentOffers.Terms memory late = terms(keccak256("slot 2"), 30_000_000);
        bytes memory heldSignature = sign(bidder, held);
        bytes memory lateSignature = sign(bidder, late);
        uint256 validBefore = vm.getBlockTimestamp() + WINDOW;
        uint256 balance = usdc.balanceOf(bidder);

        vm.warp(validBefore - 1);
        vm.prank(relayer);
        bytes32 id = offers.bid(late, bidder, 0, validBefore, lateSignature);
        vm.warp(validBefore);
        vm.expectRevert(OffersTestUSDC.AuthorizationExpired.selector);
        vm.prank(relayer);
        offers.bid(held, bidder, 0, validBefore, heldSignature);

        vm.warp(late.placeBy);
        vm.prank(stranger);
        offers.withdraw(id);
        offers.payOut(bidder);
        assertEq(usdc.balanceOf(bidder), balance);
        assertEq(usdc.balanceOf(address(offers)), 0);
    }

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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
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

    /// A stolen venue admin key can name its own operator, but never the payout wallet, the
    /// moderator or itself as moderator, so it can neither remove nor be paid.
    function test_a_stolen_admin_key_takes_nothing_already_bid() public {
        bytes32 waiting = bidOn(SLOT, 100_000_000);
        bytes32 showing = placed(keccak256("slot 2"), 200_000_000);

        vm.startPrank(admin);
        offers.setOperator(VENUE, thief);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        offers.setPayout(VENUE, thief);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        offers.setModerator(VENUE, thiefModerator);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setOperator(VENUE, moderator);
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

    /// Bids made after an admin key is stolen still pay the site: the key places them, at any
    /// length it sets, and each runs to the end, credited to the site's wallet and staking.
    function testFuzz_a_stolen_admin_key_takes_nothing_of_later_bids(uint32 length) public {
        length = uint32(bound(length, 1, LENGTH));
        vm.startPrank(admin);
        offers.setOperator(VENUE, thief);
        offers.setTerms(VENUE, MINIMUM, length);
        vm.stopPrank();

        RegentOffers.Terms memory t = terms(SLOT, 100_000_000);
        t.length = length;
        bytes32 id = bidAs(bidder, t);
        vm.startPrank(thief);
        offers.place(id);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(id);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + length);
        offers.finish(id);

        assertEq(record(id).payout, payout);
        assertEq(offers.owed(thief), 0);
        assertEq(offers.owed(payout), 90_000_000);
        assertEq(offers.revenueOwed(), 10_000_000);
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
        bytes32 two = bidAs(bidder, t);

        bytes32[2] memory venueIds = [VENUE, OTHER];
        bytes32[2] memory ids = [one, two];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(owner);
            offers.setVenueAdmin(venueIds[i], thief);
            offers.setModerator(venueIds[i], thiefModerator);
            offers.setPayout(venueIds[i], thief);
            vm.stopPrank();
            vm.prank(thief);
            offers.setOperator(venueIds[i], thiefOperator);
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

    /// Why the owner must be a multi-owner Safe: one stolen owner key names its own wallet, admin,
    /// operator and moderator, and takes 90% of a bid made after that in the bid's own block.
    /// There is no timelock (HQ, 6 Nov 2026: accepted, not fixed in code).
    function test_a_stolen_owner_key_takes_90_percent_of_a_later_bid_at_once() public {
        vm.startPrank(owner);
        offers.setVenueAdmin(VENUE, thief);
        offers.setModerator(VENUE, thiefModerator);
        offers.setPayout(VENUE, thief);
        vm.stopPrank();
        vm.prank(thief);
        offers.setOperator(VENUE, thiefOperator);

        uint256 t0 = vm.getBlockTimestamp();
        bytes32 id = bidOn(SLOT, 100_000_000);
        vm.prank(thiefOperator);
        offers.place(id);
        vm.prank(thiefModerator);
        offers.remove(id);
        offers.payOut(thief);
        assertEq(vm.getBlockTimestamp(), t0);
        assertEq(usdc.balanceOf(thief), 90_000_000);
        assertEq(offers.owed(bidder), 0);
    }

    /// A placement made while a key was stolen is cleaned up by replacing it, never by removal.
    /// Once the owner puts the wallet and keys right, a one-USDC bid of the site's own replaces
    /// the thief's placement and its bidder gets the unused time back; only the hour it showed
    /// pays the wallet stored with it. A removal would have paid that wallet the whole bid.
    function test_a_bad_placement_is_cleaned_up_by_replacing_it() public {
        vm.prank(owner);
        offers.setPayout(VENUE, thief);
        bytes32 id = bidOn(SLOT, 72_000_000);
        vm.prank(operator);
        offers.place(id);
        assertEq(record(id).payout, thief);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(owner);
        offers.setPayout(VENUE, payout);
        bytes32 own = bidOn(SLOT, MINIMUM);
        vm.prank(operator);
        offers.place(own);

        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Ended));
        assertEq(offers.live(VENUE, SLOT), own);
        assertEq(offers.owed(bidder), 71_000_000);
        assertEq(offers.owed(thief), 900_000);
        (uint256 paidIfRemoved,,, uint256 thiefIfRemoved) =
            offers.split(72_000_000, 0, LENGTH, 1 hours, RegentOffers.EndReason.Removed);
        assertEq(paidIfRemoved, 72_000_000);
        assertEq(thiefIfRemoved, 64_800_000);
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
        offers.setPayout(VENUE, thief);
        offers.setPaused(true);
        vm.stopPrank();
        vm.prank(thief);
        offers.setOperator(VENUE, thiefOperator);
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
