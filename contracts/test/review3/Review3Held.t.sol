// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {RegentOffers} from "../../src/RegentOffers.sol";
import {Review3Base, R3USDC, R3Staking} from "./Review3Base.sol";

/// @title Review3HeldTest
/// @notice Review 3 (commit 150525fd): attacks that did NOT work. Each test passes because the
///         contract refused or the sums stayed exact.
contract Review3HeldTest is Review3Base {
    // ------------------------------------------------------------ time edges

    /// One second before placeBy a bid can be placed and not withdrawn; at placeBy it is the
    /// other way round. There is no second where both or neither is possible.
    function test_R3_H1_place_and_withdraw_meet_exactly_at_place_by() public {
        (bool ok, bytes32 id,) = _enter(bidder, VENUE, SLOT, 10_000_000, LENGTH, uint64(_now() + 100));
        assertTrue(ok);
        vm.warp(_now() + 99);
        vm.expectRevert(RegentOffers.PlaceByNotPassed.selector);
        offers.withdraw(id);
        uint256 snap = vm.snapshotState();
        vm.prank(operator);
        offers.place(id);
        vm.revertToState(snap);

        vm.warp(_now() + 1);
        vm.prank(operator);
        vm.expectRevert(RegentOffers.PlaceByPassed.selector);
        offers.place(id);
        offers.withdraw(id);
        assertEq(offers.owed(bidder), 10_000_000);
    }

    /// The longest and shortest waits are taken; one second longer, or no wait, is refused.
    function test_R3_H1b_place_by_limits() public {
        (bool ok,, bytes memory why) = _enter(bidder, VENUE, SLOT, MINIMUM, LENGTH, uint64(_now()));
        assertFalse(ok);
        assertEq(bytes4(why), RegentOffers.PlaceByPassed.selector);
        (ok,, why) = _enter(bidder, VENUE, SLOT, MINIMUM, LENGTH, uint64(_now() + 72 hours + 1));
        assertFalse(ok);
        assertEq(bytes4(why), RegentOffers.PlaceByTooFar.selector);
        bytes32 soon;
        (ok, soon,) = _enter(bidder, VENUE, SLOT, MINIMUM, LENGTH, uint64(_now() + 1));
        assertTrue(ok);
        bytes32 late;
        (ok, late,) = _enter(bidder, VENUE, SLOT, MINIMUM, LENGTH, uint64(_now() + 72 hours));
        assertTrue(ok);
        vm.prank(operator);
        offers.place(soon); // placeable in its own second only
        vm.warp(_now() + 72 hours - 1);
        vm.prank(operator);
        offers.place(late);
        assertEq(offers.live(VENUE, SLOT), late);
    }

    /// 259.2 USDC over 72 hours is 1000 units a second. Replaced in its own second it pays
    /// nothing; one second short of the end it pays all but 1000 units and cannot be finished;
    /// at the end and after it pays all, by finishing or by replacing alike.
    function test_R3_H2_finish_and_replacement_at_the_exact_seconds() public {
        uint96 amount = 259_200_000;
        bytes32 id = _placed(bidder, SLOT, amount);
        uint256 snap = vm.snapshotState();

        _placed(bidder2, SLOT, MINIMUM);
        assertEq(offers.owed(bidder), amount, "same second: all back");
        assertEq(offers.owed(payout) + offers.revenueOwed(), 0);
        vm.revertToState(snap);

        vm.warp(_now() + LENGTH - 1);
        vm.expectRevert(RegentOffers.NotFinished.selector);
        offers.finish(id);
        uint256 snap2 = vm.snapshotState();
        _placed(bidder2, SLOT, MINIMUM);
        assertEq(offers.owed(bidder), 1000, "one second unused");
        assertEq(offers.owed(payout), (uint256(amount) - 1000) * 9 / 10);
        assertEq(offers.revenueOwed(), (uint256(amount) - 1000) / 10);
        vm.revertToState(snap2);

        vm.warp(_now() + 1);
        uint256 snap3 = vm.snapshotState();
        offers.finish(id);
        assertEq(offers.owed(bidder), 0);
        assertEq(offers.owed(payout), uint256(amount) * 9 / 10);
        vm.revertToState(snap3);
        _placed(bidder2, SLOT, MINIMUM);
        assertEq(offers.owed(bidder), 0, "replaced at the end: all paid");
        assertEq(offers.owed(payout), uint256(amount) * 9 / 10);
        vm.revertToState(snap3);

        vm.warp(_now() + 10 * uint256(LENGTH));
        _placed(bidder2, SLOT, MINIMUM);
        assertEq(offers.owed(bidder), 0, "long after the end: never more than the bid");
        assertEq(offers.owed(payout) + offers.revenueOwed(), amount);
    }

    // ------------------------------------------------------------ the sums

    /// Any amount, length, protocol share and time shown, ended any of the three ways: what the
    /// bidder gets back, the venue's share and staking's share add up to the bid to the unit, a
    /// replacement never pays for more than the time shown, and after paying everyone the
    /// contract holds only what is still committed.
    function testFuzz_R3_H3_one_bid_any_ending_adds_up(
        uint96 amount,
        uint32 length,
        uint64 shownFor,
        uint8 kind,
        uint16 bps
    ) public {
        bps = uint16(bound(bps, 0, 10_000));
        length = uint32(bound(length, 1, type(uint32).max));
        amount = uint96(bound(amount, 1, type(uint96).max));
        shownFor = uint64(bound(shownFor, 0, 2 * uint64(length)));
        kind = kind % 3;
        offers = new RegentOffers(usdc, staking, bps, owner);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, operator, moderator, payout, 1, length);

        bytes32 id = _placed(bidder, SLOT, amount);
        vm.warp(_now() + shownFor);

        bool replaced;
        if (kind == 1) {
            vm.prank(moderator);
            offers.remove(id);
        } else if (kind == 2 && shownFor >= length) {
            vm.prank(stranger);
            offers.finish(id);
        } else {
            if (kind == 2) {
                vm.expectRevert(RegentOffers.NotFinished.selector);
                offers.finish(id);
            }
            _placed(bidder2, SLOT, 1);
            replaced = true;
        }

        uint256 paid = amount;
        if (replaced && shownFor < length) paid = (uint256(amount) * shownFor) / length;
        uint256 protocolShare = (paid * bps) / 10_000;
        if (replaced) assertLe(paid * length, uint256(amount) * shownFor + 0, "never more than the time shown");
        assertEq(offers.owed(bidder), amount - paid, "back to the bidder");
        assertEq(offers.owed(payout), paid - protocolShare, "the venue's share");
        assertEq(offers.revenueOwed(), protocolShare, "staking's share");
        assertEq(offers.totalCommitted(), replaced ? 1 : 0);
        assertEq(offers.totalOwed(), amount - protocolShare);

        // Ended once: no second ending of any kind.
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.finish(id);
        vm.prank(moderator);
        vm.expectRevert(RegentOffers.NotPlaced.selector);
        offers.remove(id);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.withdraw(id);
        vm.prank(operator);
        vm.expectRevert(RegentOffers.NotHeld.selector);
        offers.returnBid(id);

        uint256 stakingBefore = usdc.balanceOf(address(staking));
        if (amount - paid > 0) offers.payOut(bidder);
        if (paid - protocolShare > 0) offers.payOut(payout);
        if (protocolShare > 0) offers.pushRevenue();
        assertEq(usdc.balanceOf(bidder), amount - paid);
        assertEq(usdc.balanceOf(payout), paid - protocolShare);
        assertEq(usdc.balanceOf(address(staking)) - stakingBefore, protocolShare);
        assertEq(usdc.balanceOf(address(offers)), replaced ? 1 : 0, "nothing left but what is committed");
        assertEq(usdc.allowance(address(offers), address(staking)), 0);
    }

    // ------------------------------------------------------------ the keys

    /// Any order of key changes over a wide pool (other role holders, the owner, a bidder, the
    /// contract, the token, staking, zero): each call succeeds or fails exactly as the stated
    /// rule says, a refused call changes nothing, and the moderator is never the admin or operator.
    function testFuzz_R3_H4_key_changes_in_any_order(uint16[24] memory steps) public {
        address[10] memory pool = [
            admin,
            operator,
            moderator,
            payout,
            owner,
            bidder,
            address(offers),
            address(usdc),
            address(staking),
            address(0)
        ];
        for (uint256 i; i < steps.length; ++i) {
            address next = pool[steps[i] % 10];
            uint256 kind = (steps[i] / 10) % 4;
            RegentOffers.Venue memory v = _venueOf(VENUE);
            bytes memory data;
            address caller = owner;
            bool expected;
            if (kind == 0) {
                data = abi.encodeCall(RegentOffers.setVenueAdmin, (VENUE, next));
                expected = next != address(0) && next != v.moderator;
            } else if (kind == 1) {
                data = abi.encodeCall(RegentOffers.setModerator, (VENUE, next));
                expected = next != address(0) && next != v.admin && next != v.operator;
            } else if (kind == 2) {
                data = abi.encodeCall(RegentOffers.setOperator, (VENUE, next));
                caller = v.admin;
                expected = next != address(0) && next != v.moderator;
            } else {
                data = abi.encodeCall(RegentOffers.setPayout, (VENUE, next));
                expected =
                    next != address(0) && next != address(offers) && next != address(usdc) && next != address(staking);
            }
            vm.prank(caller);
            (bool ok,) = address(offers).call(data);
            assertEq(ok, expected, "a key change is taken or refused exactly by the stated rule");
            RegentOffers.Venue memory w = _venueOf(VENUE);
            if (!ok) assertEq(keccak256(abi.encode(w)), keccak256(abi.encode(v)), "a refusal changes nothing");
            assertTrue(w.moderator != w.admin && w.moderator != w.operator, "the moderator stays apart");
            assertTrue(w.admin != address(0) && w.operator != address(0) && w.moderator != address(0));
            assertTrue(w.payout != address(0) && w.payout != address(offers) && w.payout != address(usdc));
        }
    }

    /// No key but the owner's sets the admin, moderator or payout wallet; no key but the admin's
    /// sets the operator or terms; and a key of one venue is no key on another.
    function test_R3_H4b_each_setter_has_one_caller() public {
        bytes32 other = keccak256("second.site");
        vm.prank(owner);
        offers.addVenue(other, bidder, bidder2, site, stranger, MINIMUM, LENGTH);
        address[6] memory callers = [admin, operator, moderator, payout, bidder, stranger];
        for (uint256 i; i < callers.length; ++i) {
            address c = callers[i];
            vm.startPrank(c);
            bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, c);
            vm.expectRevert(notOwner);
            offers.setVenueAdmin(VENUE, c);
            vm.expectRevert(notOwner);
            offers.setModerator(VENUE, thief);
            vm.expectRevert(notOwner);
            offers.setPayout(VENUE, c);
            vm.expectRevert(notOwner);
            offers.setPaused(true);
            vm.expectRevert(notOwner);
            offers.addVenue(keccak256("third"), c, c, thief, c, 1, 1);
            if (c != admin) {
                vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
                offers.setOperator(VENUE, c);
                vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
                offers.setTerms(VENUE, 1, 1);
            }
            vm.stopPrank();
        }
        // The first venue's admin, operator and moderator are nobody on the second.
        (bool ok, bytes32 theirs,) = _enter(thief, other, SLOT, MINIMUM, LENGTH, uint64(_now() + 1 hours));
        assertTrue(ok);
        vm.prank(admin);
        vm.expectRevert(RegentOffers.NotVenueAdmin.selector);
        offers.setOperator(other, admin);
        vm.prank(operator);
        vm.expectRevert(RegentOffers.NotOperator.selector);
        offers.place(theirs);
        vm.prank(bidder2);
        offers.place(theirs);
        vm.prank(moderator);
        vm.expectRevert(RegentOffers.NotModerator.selector);
        offers.remove(theirs);
    }

    /// Ownership moves only when the new owner accepts; until then the old owner is the owner,
    /// and nobody else can accept. It can be handed on but not given up.
    function test_R3_H5_ownership_moves_in_two_steps_and_is_never_given_up() public {
        address next = makeAddr("r3 next owner");
        vm.prank(owner);
        offers.transferOwnership(next);
        assertEq(offers.owner(), owner);
        assertEq(offers.pendingOwner(), next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        offers.setPaused(true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        offers.acceptOwnership();
        vm.prank(next);
        offers.acceptOwnership();
        assertEq(offers.owner(), next);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        offers.setPaused(true);
        vm.prank(next);
        vm.expectRevert(RegentOffers.OwnerRequired.selector);
        offers.renounceOwnership();
    }

    // ------------------------------------------------------------ recipients

    /// One recipient USDC refuses (a bidder, a payout wallet, staking) holds up only its own
    /// money: every slot still ends and everyone else is paid in full.
    function test_R3_H6_one_blocked_recipient_never_holds_up_another() public {
        bytes32 a = _placed(bidder, SLOT, 100_000_000);
        bytes32 b = _bid(bidder2, SLOT, 40_000_000);
        usdc.setBlacklisted(bidder, true);
        usdc.setBlacklisted(payout, true);
        usdc.setBlacklisted(address(staking), true);

        vm.warp(_now() + 30 minutes);
        vm.prank(operator);
        offers.place(b); // replaces a: its blocked bidder is owed the unused time
        vm.prank(moderator);
        offers.remove(b);
        assertEq(uint8(_status(a)), uint8(RegentOffers.Status.Ended));
        bytes32 c = _bid(bidder2, SLOT, 5_000_000);
        vm.prank(operator);
        offers.returnBid(c);

        offers.payOut(bidder2);
        assertEq(usdc.balanceOf(bidder2), 5_000_000);
        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, bidder));
        offers.payOut(bidder);
        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, payout));
        offers.payOut(payout);
        vm.expectRevert(abi.encodeWithSelector(R3USDC.Blacklisted.selector, address(staking)));
        offers.pushRevenue();
        assertEq(usdc.allowance(address(offers), address(staking)), 0, "a refused push leaves no approval");

        usdc.setBlacklisted(bidder, false);
        usdc.setBlacklisted(payout, false);
        usdc.setBlacklisted(address(staking), false);
        offers.payOut(bidder);
        offers.payOut(payout);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(offers)), 0);
        assertEq(offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed(), 0);
    }

    /// USDC sent straight to the contract cannot be taken by anyone, changes nobody's balance
    /// owed, and does not upset the revenue push, which measures only its own deposit.
    function test_R3_H7_a_stray_transfer_helps_and_harms_no_one() public {
        bytes32 id = _placed(bidder, SLOT, 100_000_000);
        vm.warp(_now() + LENGTH);
        offers.finish(id);
        usdc.mint(address(offers), 55_000_000);
        offers.pushRevenue();
        vm.prank(thief);
        assertEq(offers.payOut(payout), 90_000_000);
        assertEq(usdc.balanceOf(thief), 0);
        vm.expectRevert(RegentOffers.NothingOwed.selector);
        offers.payOut(thief);
        vm.expectRevert(RegentOffers.NothingOwed.selector);
        offers.pushRevenue();
        assertEq(usdc.balanceOf(address(offers)), 55_000_000, "the stray USDC stays for good");
    }

    // ------------------------------------------------------------ re-entry

    /// A token that calls the receiver on every transfer (as an upgraded USDC might), with a
    /// receiver that is the venue's payout wallet and its operator at once: while being paid it
    /// tries to place, return, bid, withdraw, finish, pay itself again and push revenue. Every
    /// attempt is refused by the guard and the sums stay exact.
    function test_R3_H8_a_recipient_called_during_payment_cannot_get_back_in() public {
        R3HookUSDC hook = new R3HookUSDC();
        usdc = hook;
        staking = new R3Staking(hook);
        offers = new RegentOffers(hook, staking, PROTOCOL_BPS, owner);
        R3Greedy greedy = new R3Greedy(offers, hook);
        vm.prank(owner);
        offers.addVenue(VENUE, admin, address(greedy), moderator, address(greedy), MINIMUM, LENGTH);

        bytes32 first = _bid(bidder, SLOT, 100_000_000);
        greedy.place(first);
        bytes32 held = _bid(bidder2, SLOT, 50_000_000);
        bytes32 showing2 = _bid(bidder2, keccak256("forum#2"), 20_000_000);
        greedy.place(showing2);
        vm.warp(_now() + LENGTH);
        offers.finish(first);

        greedy.aim(held, showing2);
        hook.arm(true);
        offers.payOut(address(greedy));
        hook.arm(false);

        assertEq(greedy.attempts(), 7);
        assertEq(greedy.refusedByGuard(), 7, "every way back in was refused");
        assertEq(hook.balanceOf(address(greedy)), 90_000_000);
        assertEq(uint8(_status(held)), uint8(RegentOffers.Status.Held));
        assertEq(hook.balanceOf(address(offers)), offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed());
    }
}

/// @notice A USDC stand-in that, when armed, calls the receiver of every transfer.
contract R3HookUSDC is R3USDC {
    bool internal armed;

    function arm(bool on) external {
        armed = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to.code.length != 0) R3Greedy(to).onReceive();
    }
}

/// @notice The venue's payout wallet and operator in one contract, trying every way back in.
contract R3Greedy {
    RegentOffers internal immutable offers;
    R3USDC internal immutable usdc;
    bytes32 internal held;
    bytes32 internal showing;
    uint256 public attempts;
    uint256 public refusedByGuard;

    constructor(RegentOffers offers_, R3USDC usdc_) {
        offers = offers_;
        usdc = usdc_;
    }

    function place(bytes32 id) external {
        offers.place(id);
    }

    function aim(bytes32 held_, bytes32 showing_) external {
        held = held_;
        showing = showing_;
    }

    function onReceive() external {
        RegentOffers.Terms memory t;
        _try(abi.encodeCall(RegentOffers.place, (held)));
        _try(abi.encodeCall(RegentOffers.returnBid, (held)));
        _try(abi.encodeCall(RegentOffers.withdraw, (held)));
        _try(abi.encodeCall(RegentOffers.finish, (showing)));
        _try(abi.encodeCall(RegentOffers.payOut, (address(this))));
        _try(abi.encodeCall(RegentOffers.pushRevenue, ()));
        _try(abi.encodeCall(RegentOffers.bid, (t, address(this), 0, type(uint256).max, "")));
    }

    function _try(bytes memory data) internal {
        ++attempts;
        (bool ok, bytes memory why) = address(offers).call(data);
        if (!ok && bytes4(why) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector) ++refusedByGuard;
    }
}
