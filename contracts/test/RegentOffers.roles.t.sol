// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RegentOffers} from "../src/RegentOffers.sol";
import {OffersSetUp} from "./RegentOffers.t.sol";

/// @title RegentOffersRolesTest
/// @notice Who may call what. The owner names each venue's admin, moderator and payout wallet; the
///         admin names the operator and sets the terms; the operator places and returns; the
///         moderator only removes, and is never the venue's admin or operator. Every setter refuses
///         zero values, zero addresses and unknown venues, and a refusal changes nothing.
contract RegentOffersRolesTest is OffersSetUp {
    address internal fresh = makeAddr("fresh key");

    function venue() internal view returns (RegentOffers.Venue memory v) {
        (v.admin, v.operator, v.moderator, v.payout, v.minimum, v.length) = offers.venues(VENUE);
    }

    function assertVenueUnchanged() internal view {
        RegentOffers.Venue memory v = venue();
        assertEq(v.admin, admin, "admin");
        assertEq(v.operator, operator, "operator");
        assertEq(v.moderator, moderator, "moderator");
        assertEq(v.payout, payout, "payout");
        assertEq(v.minimum, MINIMUM, "minimum");
        assertEq(v.length, LENGTH, "length");
    }

    // ------------------------------------------------------------ the moderator

    /// A removal pays the whole bid, so no key but the moderator removes.
    function test_only_the_moderator_removes() public {
        bytes32 id = placed(SLOT, 10_000_000);
        address[6] memory others = [owner, admin, operator, payout, bidder, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(RegentOffers.NotModerator.selector);
            offers.remove(id);
        }
        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Placed));
        vm.prank(moderator);
        offers.remove(id);
        assertEq(uint8(status(id)), uint8(RegentOffers.Status.Ended));
    }

    /// The moderator can do nothing but remove.
    function test_the_moderator_only_removes() public {
        bytes32 waiting = bidOn(SLOT, 10_000_000);
        vm.startPrank(moderator);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(waiting);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(waiting);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(VENUE, fresh);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setTerms(VENUE, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        offers.setPayout(VENUE, moderator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        offers.setVenueAdmin(VENUE, fresh);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, moderator));
        offers.setPaused(true);
        vm.stopPrank();
        assertVenueUnchanged();
        assertEq(uint8(status(waiting)), uint8(RegentOffers.Status.Held));
    }

    /// The moderator is never the venue's admin or its operator, whichever of the three changes.
    function test_the_moderator_is_never_the_admin_or_the_operator() public {
        vm.startPrank(owner);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.addVenue(OTHER, admin2, operator2, admin2, payout2, MINIMUM, LENGTH);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.addVenue(OTHER, admin2, operator2, operator2, payout2, MINIMUM, LENGTH);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setModerator(VENUE, admin);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setModerator(VENUE, operator);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setVenueAdmin(VENUE, moderator);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(RegentOffers.ModeratorNotSeparate.selector);
        offers.setOperator(VENUE, moderator);

        assertVenueUnchanged();
        (address otherAdmin,,,,,) = offers.venues(OTHER);
        assertEq(otherAdmin, address(0), "the second venue was never added");
    }

    /// The admin and the operator may be one key: it places but still never removes.
    function test_the_admin_may_also_be_the_operator() public {
        vm.prank(admin);
        offers.setOperator(VENUE, admin);
        bytes32 id = bidOn(SLOT, 10_000_000);
        vm.startPrank(admin);
        offers.place(id);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(id);
        vm.stopPrank();
    }

    /// No order of key changes, by the owner or the admin, ever leaves the moderator holding the
    /// admin's or the operator's key.
    function testFuzz_no_key_change_makes_the_moderator_a_placing_key(uint8[12] memory steps) public {
        address[4] memory pool = [admin, operator, moderator, fresh];
        for (uint256 i; i < steps.length; ++i) {
            address next = pool[steps[i] % 4];
            uint256 kind = (steps[i] / 4) % 3;
            RegentOffers.Venue memory v = venue();
            bytes memory call_ = kind == 0
                ? abi.encodeCall(RegentOffers.setVenueAdmin, (VENUE, next))
                : kind == 1
                    ? abi.encodeCall(RegentOffers.setModerator, (VENUE, next))
                    : abi.encodeCall(RegentOffers.setOperator, (VENUE, next));
            vm.prank(kind == 2 ? v.admin : owner);
            (bool ok,) = address(offers).call(call_);
            bool clash = kind == 0
                ? next == v.moderator
                : kind == 1 ? next == v.admin || next == v.operator : next == v.moderator;
            assertEq(ok, !clash, "a key change is refused exactly when it would join the moderator to another key");
            v = venue();
            assertTrue(v.moderator != v.admin && v.moderator != v.operator, "the moderator stays apart");
        }
    }

    // ------------------------------------------------------------ the owner

    /// Only the owner names a venue's admin, moderator and payout wallet, pauses, adds a venue or
    /// hands ownership on. A venue admin can no longer point a venue's money at a new wallet.
    function test_only_the_owner_names_admins_moderators_and_payout_wallets() public {
        address[5] memory notOwner = [admin, operator, moderator, payout, stranger];
        for (uint256 i; i < notOwner.length; ++i) {
            bytes memory why = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner[i]);
            vm.startPrank(notOwner[i]);
            vm.expectRevert(why);
            offers.setVenueAdmin(VENUE, fresh);
            vm.expectRevert(why);
            offers.setModerator(VENUE, fresh);
            vm.expectRevert(why);
            offers.setPayout(VENUE, notOwner[i]);
            vm.expectRevert(why);
            offers.setPaused(true);
            vm.expectRevert(why);
            offers.addVenue(OTHER, admin2, operator2, moderator2, payout2, MINIMUM, LENGTH);
            vm.expectRevert(why);
            offers.transferOwnership(notOwner[i]);
            vm.stopPrank();
        }
        assertVenueUnchanged();
        assertFalse(offers.paused());
        assertEq(offers.owner(), owner);

        vm.prank(owner);
        offers.setPayout(VENUE, fresh);
        assertEq(venue().payout, fresh);
        assertEq(record(bidOn(SLOT, MINIMUM)).payout, fresh);
    }

    /// The owner holds no key that places, returns or removes, and does not name the operator or
    /// set the terms.
    function test_the_owner_holds_no_key_that_places_or_removes() public {
        bytes32 waiting = bidOn(SLOT, 10_000_000);
        bytes32 showing = placed(keccak256("slot 2"), 10_000_000);
        vm.startPrank(owner);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(VENUE, owner);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setTerms(VENUE, 1, 1);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(waiting);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.returnBid(waiting);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(showing);
        vm.stopPrank();
        assertVenueUnchanged();
    }

    // ------------------------------------------------------------ the admin

    /// Only the venue's admin names its operator and sets its terms.
    function test_only_the_admin_names_the_operator_and_sets_the_terms() public {
        address[5] memory notAdmin = [owner, operator, moderator, payout, stranger];
        for (uint256 i; i < notAdmin.length; ++i) {
            vm.startPrank(notAdmin[i]);
            vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
            offers.setOperator(VENUE, fresh);
            vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
            offers.setTerms(VENUE, 1, 1);
            vm.stopPrank();
        }
        assertVenueUnchanged();

        vm.startPrank(admin);
        offers.setOperator(VENUE, fresh);
        offers.setTerms(VENUE, 2_000_000, 1 hours);
        vm.stopPrank();
        RegentOffers.Venue memory v = venue();
        assertEq(v.operator, fresh);
        assertEq(v.minimum, 2_000_000);
        assertEq(v.length, 1 hours);
    }

    /// A replaced admin key can do nothing from that moment; the new one can.
    function test_the_owner_replaces_a_lost_admin() public {
        vm.prank(owner);
        offers.setVenueAdmin(VENUE, fresh);
        vm.prank(admin);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(VENUE, admin);
        vm.prank(fresh);
        offers.setOperator(VENUE, fresh);
        assertEq(venue().operator, fresh);
    }

    // ------------------------------------------------------------ zero values

    /// Every setter refuses a zero value, a zero address and an unknown venue, and changes nothing.
    function test_zero_values_zero_addresses_and_unknown_venues_are_refused() public {
        bytes32 unknown = keccak256("unknown venue");
        vm.startPrank(admin);
        vm.expectRevert(RegentOffers.ZeroValue.selector);
        offers.setTerms(VENUE, 0, LENGTH);
        vm.expectRevert(RegentOffers.ZeroValue.selector);
        offers.setTerms(VENUE, MINIMUM, 0);
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.setOperator(VENUE, address(0));
        vm.expectRevert(RegentOffers.VenueNotFound.selector);
        offers.setOperator(unknown, fresh);
        vm.expectRevert(RegentOffers.VenueNotFound.selector);
        offers.setTerms(unknown, 1, 1);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.setVenueAdmin(VENUE, address(0));
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.setModerator(VENUE, address(0));
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.setPayout(VENUE, address(0));
        vm.expectRevert(RegentOffers.VenueNotFound.selector);
        offers.setVenueAdmin(unknown, fresh);
        vm.expectRevert(RegentOffers.VenueNotFound.selector);
        offers.setModerator(unknown, fresh);
        vm.expectRevert(RegentOffers.VenueNotFound.selector);
        offers.setPayout(unknown, fresh);
        vm.expectRevert(RegentOffers.ZeroValue.selector);
        offers.addVenue(bytes32(0), admin2, operator2, moderator2, payout2, MINIMUM, LENGTH);
        vm.expectRevert(RegentOffers.ZeroValue.selector);
        offers.addVenue(OTHER, admin2, operator2, moderator2, payout2, 0, LENGTH);
        vm.expectRevert(RegentOffers.ZeroValue.selector);
        offers.addVenue(OTHER, admin2, operator2, moderator2, payout2, MINIMUM, 0);
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.addVenue(OTHER, address(0), operator2, moderator2, payout2, MINIMUM, LENGTH);
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.addVenue(OTHER, admin2, address(0), moderator2, payout2, MINIMUM, LENGTH);
        vm.expectRevert(RegentOffers.ZeroAddress.selector);
        offers.addVenue(OTHER, admin2, operator2, address(0), payout2, MINIMUM, LENGTH);
        vm.stopPrank();

        assertVenueUnchanged();
        (address otherAdmin,,,,,) = offers.venues(OTHER);
        assertEq(otherAdmin, address(0));
    }
}
