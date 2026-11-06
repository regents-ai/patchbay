// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegentOffers} from "../../src/RegentOffers.sol";
import {Review3Entry, R3USDC, R3Staking} from "./Review3Base.sol";

/// @notice Review 3's own random driver. It differs from the suite's handler on purpose: one pool
///         of six addresses fills every seat (bidder, payout wallet, admin, operator, moderator),
///         so wallets overlap in every allowed way; key changes also try the contract, the token,
///         staking and zero; bids run up to the largest amount a bid can carry; lengths run from
///         one second to the largest a venue can set; USDC can block any of the six, staking, or
///         the contract itself; staking can refuse. Every call the rules say must work is
///         required to work, and every call they say must fail is required to fail.
contract R3Handler is Review3Entry {
    R3Staking internal staking;
    address internal owner;
    uint256 public bps;

    bytes32[2] public venueIds = [keccak256("r3 venue a"), keccak256("r3 venue b")];
    bytes32[3] public slotIds = [keccak256("r3 slot 1"), keccak256("r3 slot 2"), keccak256("r3 slot 3")];
    uint32[5] internal lengths = [uint32(1), 7, 1 hours, 72 hours, type(uint32).max];
    address[6] public people;
    address[4] internal specials;
    bytes32[] public ids;

    mapping(bytes32 id => address) public payoutOf;
    mapping(address => uint256) public credited;
    mapping(address => uint256) public paidTo;
    uint256 public sumIn;
    uint256 public paidOut;
    uint256 public pushed;
    uint256 public expectedRevenue;

    constructor(R3USDC usdc_, R3Staking staking_, RegentOffers offers_, address owner_, uint256 bps_) {
        usdc = usdc_;
        staking = staking_;
        offers = offers_;
        owner = owner_;
        bps = bps_;
        for (uint256 i; i < 6; ++i) {
            people[i] = makeAddr(string.concat("r3 person ", vm.toString(i)));
        }
        specials = [address(offers), address(usdc), address(staking), address(0)];
        vm.startPrank(owner);
        offers.addVenue(venueIds[0], people[0], people[1], people[2], people[3], 1_000_000, 72 hours);
        // The second venue starts with every allowed overlap: admin = operator = payout.
        offers.addVenue(venueIds[1], people[1], people[1], people[0], people[1], 1, 7);
        vm.stopPrank();
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    // ------------------------------------------------------------ bids

    function bid(uint8 who, uint8 venue, uint8 slot, uint96 amount, uint32 within, uint8 dice) external {
        bytes32 v = venueIds[venue % 2];
        address from = people[who % 6];
        RegentOffers.Venue memory terms = _venueOf(v);
        uint256 most = dice < 200 ? 1_000_000_000_000 : type(uint96).max;
        amount = uint96(bound(amount, terms.minimum, most));
        uint64 placeBy = uint64(vm.getBlockTimestamp() + bound(within, 1, 72 hours));
        (bool ok, bytes32 id,) = _enter(from, v, slotIds[slot % 3], amount, terms.length, placeBy);
        bool expected = !offers.paused() && !usdc.blacklisted(from) && !usdc.blacklisted(address(offers));
        assertEq(ok, expected, "a bid is taken exactly when bids are open and USDC lets it move");
        if (!ok) return;
        ids.push(id);
        payoutOf[id] = terms.payout;
        sumIn += amount;
    }

    function place(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _rec(id);
        if (b.status != RegentOffers.Status.Held) return;
        bool expected = vm.getBlockTimestamp() < b.placeBy;
        bytes32 current = offers.live(b.venue, b.slot);
        if (expected && current != bytes32(0)) _book(current, true);
        vm.prank(_venueOf(b.venue).operator);
        (bool ok,) = address(offers).call(abi.encodeCall(RegentOffers.place, (id)));
        assertEq(ok, expected, "placing works until placeBy and never from it");
        if (!ok) return;
        b = _rec(id);
        assertEq(uint8(b.status), uint8(RegentOffers.Status.Placed));
        assertEq(b.startsAt, vm.getBlockTimestamp(), "a placement starts now, never earlier");
        assertEq(offers.live(b.venue, b.slot), id);
    }

    function returnBid(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _rec(id);
        if (b.status != RegentOffers.Status.Held) return;
        credited[b.bidder] += b.amount;
        vm.prank(_venueOf(b.venue).operator);
        offers.returnBid(id);
    }

    function withdraw(uint256 i, uint8 who) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _rec(id);
        if (b.status != RegentOffers.Status.Held) return;
        bool expected = vm.getBlockTimestamp() >= b.placeBy;
        vm.prank(people[who % 6]);
        (bool ok,) = address(offers).call(abi.encodeCall(RegentOffers.withdraw, (id)));
        assertEq(ok, expected, "anyone withdraws from placeBy and no one before");
        if (ok) credited[b.bidder] += b.amount;
    }

    function remove(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _rec(id);
        if (b.status != RegentOffers.Status.Placed) return;
        _book(id, false);
        vm.prank(_venueOf(b.venue).moderator);
        offers.remove(id);
    }

    function finish(uint256 i, uint8 who) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _rec(id);
        if (b.status != RegentOffers.Status.Placed) return;
        bool expected = vm.getBlockTimestamp() >= uint256(b.startsAt) + b.length;
        vm.prank(people[who % 6]);
        (bool ok,) = address(offers).call(abi.encodeCall(RegentOffers.finish, (id)));
        assertEq(ok, expected, "anyone finishes from the end time and no one before");
        if (ok) _book(id, false);
    }

    // ------------------------------------------------------------ paying

    function payOut(uint8 k, uint8 who) external {
        address account = people[k % 6];
        uint256 due = offers.owed(account);
        uint256 before = usdc.balanceOf(account);
        bool expected = due != 0 && !usdc.blacklisted(account) && !usdc.blacklisted(address(offers));
        vm.prank(people[who % 6]);
        (bool ok,) = address(offers).call(abi.encodeCall(RegentOffers.payOut, (account)));
        assertEq(ok, expected, "an account is paid exactly when it is owed and USDC lets it be paid");
        if (ok) {
            assertEq(usdc.balanceOf(account) - before, due, "paid exactly what was owed, to that account");
            paidTo[account] += due;
            paidOut += due;
        } else {
            assertEq(offers.owed(account), due, "a refused payment leaves the debt as it was");
        }
    }

    function pushRevenue(uint8 who) external {
        uint256 due = offers.revenueOwed();
        bool expected = due != 0 && !staking.refusing() && !usdc.blacklisted(address(staking))
            && !usdc.blacklisted(address(offers));
        vm.prank(people[who % 6]);
        (bool ok,) = address(offers).call(abi.encodeCall(RegentOffers.pushRevenue, ()));
        assertEq(ok, expected, "the staking share moves exactly when there is one and staking takes it");
        if (ok) pushed += due;
        else assertEq(offers.revenueOwed(), due);
    }

    // ------------------------------------------------------------ keys and settings

    function setKey(uint8 venue, uint8 kind, uint8 k) external {
        bytes32 v = venueIds[venue % 2];
        address next = k % 10 < 7 ? people[k % 6] : specials[k % 4];
        RegentOffers.Venue memory was = _venueOf(v);
        kind %= 4;
        bytes memory data;
        address caller = owner;
        bool expected;
        if (kind == 0) {
            data = abi.encodeCall(RegentOffers.setVenueAdmin, (v, next));
            expected = next != address(0) && next != was.moderator;
        } else if (kind == 1) {
            data = abi.encodeCall(RegentOffers.setModerator, (v, next));
            expected = next != address(0) && next != was.admin && next != was.operator;
        } else if (kind == 2) {
            data = abi.encodeCall(RegentOffers.setOperator, (v, next));
            caller = was.admin;
            expected = next != address(0) && next != was.moderator;
        } else {
            data = abi.encodeCall(RegentOffers.setPayout, (v, next));
            expected = next != address(0) && next != specials[0] && next != specials[1] && next != specials[2];
        }
        vm.prank(caller);
        (bool ok,) = address(offers).call(data);
        assertEq(ok, expected, "a key change is taken or refused exactly by the stated rule");
    }

    function setTerms(uint8 venue, uint96 minimum, uint8 k) external {
        bytes32 v = venueIds[venue % 2];
        vm.prank(_venueOf(v).admin);
        offers.setTerms(v, uint96(bound(minimum, 1, 5_000_000)), lengths[k % 5]);
    }

    function setBlocked(uint8 k, uint8 dice) external {
        address target = k % 8 < 6 ? people[k % 6] : k % 8 == 6 ? address(staking) : address(offers);
        usdc.setBlacklisted(target, dice < 60);
    }

    function setRefusing(uint8 dice) external {
        staking.setRefusing(dice < 50);
    }

    function setPaused(uint8 dice) external {
        vm.prank(owner);
        offers.setPaused(dice < 40);
    }

    function wait(uint32 seconds_, uint8 dice) external {
        uint256 most = dice < 100 ? 3 : dice < 220 ? 2 hours : 5 days;
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, most));
    }

    // ------------------------------------------------------------ the driver's own book

    /// @dev What an ending now must credit, worked out apart from the contract.
    function _book(bytes32 id, bool replaced) internal {
        RegentOffers.Bid memory b = _rec(id);
        uint256 paid = b.amount;
        if (replaced) {
            uint256 shown = vm.getBlockTimestamp() - b.startsAt;
            if (shown < b.length) paid = (uint256(b.amount) * shown) / b.length;
        }
        uint256 protocolShare = (paid * bps) / 10_000;
        credited[b.bidder] += b.amount - paid;
        credited[payoutOf[id]] += paid - protocolShare;
        expectedRevenue += protocolShare;
    }
}

abstract contract Review3InvariantBase is Test {
    R3USDC internal usdc;
    R3Staking internal staking;
    RegentOffers internal offers;
    R3Handler internal handler;

    function _bps() internal pure virtual returns (uint256);

    function setUp() public {
        vm.warp(1_800_000_000);
        address owner = makeAddr("r3 owner");
        usdc = new R3USDC();
        staking = new R3Staking(usdc);
        offers = new RegentOffers(usdc, staking, _bps(), owner);
        handler = new R3Handler(usdc, staking, offers, owner, _bps());
        targetContract(address(handler));
    }

    function _check() internal view {
        // Money in equals money still held plus money sent out; money held is exactly what the
        // contract's three records say.
        uint256 held = usdc.balanceOf(address(offers));
        assertEq(held, offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed(), "held vs records");
        assertEq(handler.sumIn(), held + handler.paidOut() + handler.pushed(), "in vs held and out");
        assertEq(usdc.balanceOf(address(staking)), handler.pushed(), "staking received");
        assertEq(offers.revenueOwed() + handler.pushed(), handler.expectedRevenue(), "staking's share");
        assertEq(usdc.allowance(address(offers), address(staking)), 0, "no approval left with staking");

        uint256 owedSum;
        for (uint256 i; i < 6; ++i) {
            address person = handler.people(i);
            uint256 owed = offers.owed(person);
            owedSum += owed;
            assertEq(owed + handler.paidTo(person), handler.credited(person), "an account's credit");
        }
        assertEq(owedSum, offers.totalOwed(), "sum of owed");

        uint256 committed;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            (, uint96 amount, bytes32 venue, bytes32 slot, address payout,,,, RegentOffers.Status s) = offers.bids(id);
            assertEq(payout, handler.payoutOf(id), "a bid keeps the wallet it was made under");
            if (s == RegentOffers.Status.Held || s == RegentOffers.Status.Placed) committed += amount;
            if (s == RegentOffers.Status.Placed) {
                assertEq(offers.live(venue, slot), id, "a showing bid is the live one");
            }
        }
        assertEq(committed, offers.totalCommitted(), "committed");

        for (uint256 v; v < 2; ++v) {
            (address admin, address operator, address moderator, address payout,,) = offers.venues(handler.venueIds(v));
            assertTrue(moderator != admin && moderator != operator, "the moderator stays apart");
            assertTrue(payout != address(0) && payout != address(offers) && payout != address(usdc), "payout");
            for (uint256 k; k < 3; ++k) {
                bytes32 liveId = offers.live(handler.venueIds(v), handler.slotIds(k));
                if (liveId == bytes32(0)) continue;
                (,,,,,,,, RegentOffers.Status s) = offers.bids(liveId);
                assertEq(uint8(s), uint8(RegentOffers.Status.Placed), "a live id is a showing bid");
            }
        }
    }
}

/// @title Review3InvariantTest
/// @notice The sums with the 10% share the README names.
contract Review3InvariantTest is Review3InvariantBase {
    function _bps() internal pure override returns (uint256) {
        return 1000;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_R3_money_in_equals_money_owed_plus_money_out() public view {
        _check();
    }
}

/// @title Review3InvariantOddShareTest
/// @notice The same with a share that never divides evenly, to stress the rounding.
contract Review3InvariantOddShareTest is Review3InvariantBase {
    function _bps() internal pure override returns (uint256) {
        return 3333;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_R3_money_in_equals_money_owed_plus_money_out_odd_share() public view {
        _check();
    }
}
