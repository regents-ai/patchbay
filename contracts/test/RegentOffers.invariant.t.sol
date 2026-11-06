// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegentOffers} from "../src/RegentOffers.sol";
import {OffersTestUSDC, OffersTestStaking} from "./OffersTestTokens.sol";

/// @notice Drives RegentOffers through random bids, placements, endings, payouts and time, as an
///         operator, strangers and bidders would, and keeps what the invariants compare against.
contract OffersHandler is Test {
    OffersTestUSDC internal usdc;
    RegentOffers internal offers;
    address internal operator;
    address internal moderator;

    bytes32 internal constant VENUE = keccak256("patchbay.help");
    uint32 internal constant LENGTH = 72 hours;
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256[3] internal keys = [uint256(0xA11CE), 0xB0B, 0xCA7];
    bytes32[3] internal slots = [keccak256("slot 1"), keccak256("slot 2"), keccak256("slot 3")];

    bytes32[] public ids;
    uint256 public strayIn;
    uint256 internal salt;

    constructor(OffersTestUSDC usdc_, RegentOffers offers_, address operator_, address moderator_) {
        usdc = usdc_;
        offers = offers_;
        operator = operator_;
        moderator = moderator_;
        for (uint256 i; i < keys.length; ++i) {
            usdc.mint(vm.addr(keys[i]), type(uint96).max);
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function slotAt(uint256 i) external view returns (bytes32) {
        return slots[i];
    }

    function bid(uint256 who, uint256 slot, uint96 amount, uint32 placeWithin) external {
        uint256 key = keys[who % keys.length];
        address from = vm.addr(key);
        RegentOffers.Terms memory t = RegentOffers.Terms({
            venue: VENUE,
            slot: slots[slot % slots.length],
            lane: uint8(salt % 2),
            wordingHash: keccak256(abi.encode(salt)),
            amount: uint96(bound(amount, 1_000_000, 1_000_000_000_000)),
            length: LENGTH,
            placeBy: uint64(vm.getBlockTimestamp() + bound(placeWithin, 1, 4 days)),
            salt: bytes32(++salt)
        });
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_TYPEHASH, from, address(offers), t.amount, uint256(0), validBefore, keccak256(abi.encode(t))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        ids.push(offers.bid(t, from, 0, validBefore, abi.encodePacked(r, s, v)));
    }

    function place(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        if (_status(id) != RegentOffers.Status.Held || vm.getBlockTimestamp() >= _placeBy(id)) return;
        vm.prank(operator);
        offers.place(id);
    }

    function returnBid(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        if (_status(id) != RegentOffers.Status.Held) return;
        vm.prank(operator);
        offers.returnBid(id);
    }

    function remove(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        if (_status(id) != RegentOffers.Status.Placed) return;
        vm.prank(moderator);
        offers.remove(id);
    }

    function withdraw(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        if (_status(id) != RegentOffers.Status.Held || vm.getBlockTimestamp() < _placeBy(id)) return;
        offers.withdraw(id);
    }

    function finish(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        if (_status(id) != RegentOffers.Status.Placed) return;
        (,,,,, uint64 starts, uint32 length,) = offers.bids(id);
        if (vm.getBlockTimestamp() < uint256(starts) + length) return;
        offers.finish(id);
    }

    function payOut(uint256 who) external {
        address account = who % 4 == 3 ? _payout() : vm.addr(keys[who % keys.length]);
        if (offers.owed(account) == 0) return;
        offers.payOut(account);
    }

    function pushRevenue() external {
        if (offers.revenueOwed() == 0) return;
        offers.pushRevenue();
    }

    function sendStray(uint96 amount) external {
        amount = uint96(bound(amount, 1, 1_000_000_000));
        usdc.mint(address(offers), amount);
        strayIn += amount;
    }

    function wait(uint32 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 5 days));
    }

    function _payout() internal view returns (address p) {
        (,,, p,,) = offers.venues(VENUE);
    }

    function _status(bytes32 id) internal view returns (RegentOffers.Status s) {
        (,,,,,,, s) = offers.bids(id);
    }

    function _placeBy(bytes32 id) internal view returns (uint64 p) {
        (,,,, p,,,) = offers.bids(id);
    }
}

/// @title RegentOffersInvariantTest
/// @notice Whatever happens, the contract's USDC is exactly what bids hold, what is owed to accounts,
///         the revenue owed and any USDC sent to it directly; the records agree with every bid; and
///         a slot never shows two placements.
contract RegentOffersInvariantTest is Test {
    OffersTestUSDC internal usdc;
    OffersTestStaking internal staking;
    RegentOffers internal offers;
    OffersHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        address owner = makeAddr("owner");
        address operator = makeAddr("operator");
        address moderator = makeAddr("moderator");
        usdc = new OffersTestUSDC();
        staking = new OffersTestStaking(usdc);
        offers = new RegentOffers(usdc, staking, 1000, owner);
        vm.prank(owner);
        offers.addVenue(
            keccak256("patchbay.help"), makeAddr("admin"), operator, moderator, makeAddr("payout"), 1_000_000, 72 hours
        );
        handler = new OffersHandler(usdc, offers, operator, moderator);
        targetContract(address(handler));
    }

    function invariant_usdc_held_is_exactly_what_is_accounted_for() public view {
        assertEq(
            usdc.balanceOf(address(offers)),
            offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed() + handler.strayIn()
        );
    }

    function invariant_committed_is_the_sum_of_held_and_placed_bids() public view {
        uint256 committed;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            (, uint96 amount,,,,,, RegentOffers.Status s) = offers.bids(handler.ids(i));
            if (s == RegentOffers.Status.Held || s == RegentOffers.Status.Placed) committed += amount;
        }
        assertEq(offers.totalCommitted(), committed);
    }

    function invariant_each_slot_shows_at_most_its_one_live_placement() public view {
        uint256 n = handler.idCount();
        for (uint256 k; k < 3; ++k) {
            bytes32 slot = handler.slotAt(k);
            bytes32 shown = offers.live(keccak256("patchbay.help"), slot);
            uint256 placedHere;
            for (uint256 i; i < n; ++i) {
                bytes32 id = handler.ids(i);
                (,,, bytes32 bidSlot,,,, RegentOffers.Status s) = offers.bids(id);
                if (bidSlot == slot && s == RegentOffers.Status.Placed) {
                    ++placedHere;
                    assertEq(id, shown);
                }
            }
            assertLe(placedHere, 1);
            if (placedHere == 0) assertEq(shown, bytes32(0));
        }
    }
}
