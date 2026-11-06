// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegentOffers} from "../src/RegentOffers.sol";
import {OffersTestUSDC, OffersTestStaking, OffersTestWallet} from "./OffersTestTokens.sol";

/// @notice Drives RegentOffers through random bids, placements, endings, payouts and time on two
///         venues that share slot ids, every bid a signed USDC authorization submitted by a
///         relayer with no role, with an ERC-1271 contract-wallet bidder, payout wallets that rotate
///         (one of them is also a bidder), operators that rotate, changing terms (lengths of 1 s,
///         60 s and 72 h), pausing, blocked addresses and waits of zero seconds. It keeps its own
///         book of what every account should have been credited, worked out apart from the
///         contract, including which payout wallet each bid was made under.
contract OffersHandler is Test {
    OffersTestUSDC internal usdc;
    OffersTestStaking internal staking;
    RegentOffers internal offers;
    address internal owner;

    bytes32[2] public venueIds = [keccak256("patchbay.help"), keccak256("second.site")];
    bytes32[2] public slots = [keccak256("slot 1"), keccak256("slot 2")];
    uint32[3] internal lengths = [uint32(1), 60, 72 hours];
    address[2] internal admins;
    address[2] internal moderators;
    address[2] internal operatorPool;
    address[2] internal operators;
    address[2] internal payouts;

    address[4] internal bidders;
    uint256[3] internal keys;
    address internal relayer = makeAddr("relayer");
    address[] public accounts;

    bytes32[] public ids;
    uint256 internal salt;

    mapping(bytes32 id => address) public payoutOf;
    mapping(address => uint256) public expectedCredit;
    mapping(address => uint256) public paidTo;
    uint256 public expectedRevenue;
    uint256 public pushed;
    /// @dev USDC sent in other than through a bid and not yet recovered.
    uint256 public strayIn;
    uint256 public strayTotal;
    uint256 public recovered;
    address public rescuer = makeAddr("rescuer");
    uint256 public deposited;

    constructor(OffersTestUSDC usdc_, OffersTestStaking staking_, RegentOffers offers_, address owner_) {
        usdc = usdc_;
        staking = staking_;
        offers = offers_;
        owner = owner_;
        (bidders[0], keys[0]) = makeAddrAndKey("bidder a");
        (bidders[1], keys[1]) = makeAddrAndKey("bidder b");
        (bidders[2], keys[2]) = makeAddrAndKey("bidder c");
        // The contract wallet accepts bidder a's key.
        bidders[3] = address(new OffersTestWallet(bidders[0]));
        for (uint256 i; i < 4; ++i) {
            usdc.mint(bidders[i], type(uint96).max);
            accounts.push(bidders[i]);
        }
        accounts.push(makeAddr("payout a"));
        accounts.push(makeAddr("payout b"));
        accounts.push(makeAddr("payout c"));
        operatorPool = [makeAddr("operator x"), makeAddr("operator y")];
        for (uint256 v; v < 2; ++v) {
            admins[v] = makeAddr(v == 0 ? "admin 0" : "admin 1");
            moderators[v] = makeAddr(v == 0 ? "moderator 0" : "moderator 1");
            operators[v] = operatorPool[v];
            payouts[v] = accounts[4 + v];
            vm.prank(owner);
            offers.addVenue(venueIds[v], admins[v], operators[v], moderators[v], payouts[v], 1_000_000, 72 hours);
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    // ------------------------------------------------------------ actions

    function bid(uint256 who, uint256 venue, uint256 slot, uint96 amount, uint32 placeWithin) external {
        if (offers.paused()) return;
        who %= 4;
        if (usdc.blocked(bidders[who])) return;
        venue %= 2;
        RegentOffers.Terms memory t = _terms(venueIds[venue], slots[slot % 2], amount, placeWithin);
        bytes32 id = _bidAs(who, t);
        ids.push(id);
        payoutOf[id] = payouts[venue];
        deposited += t.amount;
    }

    function bidAndPlace(uint256 who, uint256 venue, uint256 slot, uint96 amount, uint32 placeWithin) external {
        uint256 before = ids.length;
        this.bid(who, venue, slot, amount, placeWithin);
        if (ids.length > before) _place(ids[before]);
    }

    function place(uint256 i) external {
        if (ids.length == 0) return;
        _place(ids[i % ids.length]);
    }

    function returnBid(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _record(id);
        if (b.status != RegentOffers.Status.Held) return;
        expectedCredit[b.bidder] += b.amount;
        vm.prank(operators[_venue(b.venue)]);
        offers.returnBid(id);
    }

    function withdraw(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _record(id);
        if (b.status != RegentOffers.Status.Held || vm.getBlockTimestamp() < b.placeBy) return;
        expectedCredit[b.bidder] += b.amount;
        offers.withdraw(id);
    }

    function remove(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _record(id);
        if (b.status != RegentOffers.Status.Placed) return;
        _expectEnd(id, false);
        vm.prank(moderators[_venue(b.venue)]);
        offers.remove(id);
    }

    function finish(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        RegentOffers.Bid memory b = _record(id);
        if (b.status != RegentOffers.Status.Placed || vm.getBlockTimestamp() < uint256(b.startsAt) + b.length) {
            return;
        }
        _expectEnd(id, false);
        offers.finish(id);
    }

    function payOut(uint256 k) external {
        address account = accounts[k % accounts.length];
        if (offers.owed(account) == 0 || usdc.blocked(account)) return;
        paidTo[account] += offers.payOut(account);
    }

    function pushRevenue() external {
        if (offers.revenueOwed() == 0) return;
        pushed += offers.pushRevenue();
    }

    function setPayout(uint256 venue, uint256 k) external {
        venue %= 2;
        // accounts[3] is the contract-wallet bidder, so a payout wallet can also be a bidder.
        payouts[venue] = accounts[3 + (k % 4)];
        vm.prank(owner);
        offers.setPayout(venueIds[venue], payouts[venue]);
    }

    function setOperator(uint256 venue, uint256 k) external {
        venue %= 2;
        operators[venue] = operatorPool[k % 2];
        vm.prank(admins[venue]);
        offers.setOperator(venueIds[venue], operators[venue]);
    }

    function setTerms(uint256 venue, uint96 minimum, uint256 k) external {
        venue %= 2;
        vm.prank(admins[venue]);
        offers.setTerms(venueIds[venue], uint96(bound(minimum, 1, 5_000_000)), lengths[k % 3]);
    }

    function setBlocked(uint256 k, uint8 dice) external {
        usdc.setBlocked(accounts[k % accounts.length], dice < 64);
    }

    function setPaused(uint8 dice) external {
        vm.prank(owner);
        offers.setPaused(dice < 26);
    }

    function sendStray(uint96 amount) external {
        amount = uint96(bound(amount, 1, 1_000_000_000));
        usdc.mint(address(offers), amount);
        strayIn += amount;
        strayTotal += amount;
    }

    function recoverSurplus() external {
        if (strayIn == 0) return;
        vm.prank(owner);
        uint256 got = offers.recoverSurplus(rescuer);
        assertEq(got, strayIn, "only the stray USDC is surplus");
        recovered += got;
        strayIn = 0;
    }

    function wait(uint32 seconds_, uint8 dice) external {
        uint256 most = dice < 128 ? 90 : dice < 230 ? 6 hours : 4 days;
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, most));
    }

    // ------------------------------------------------------------ the handler's own book

    function _place(bytes32 id) internal {
        RegentOffers.Bid memory b = _record(id);
        if (b.status != RegentOffers.Status.Held || vm.getBlockTimestamp() >= b.placeBy) return;
        bytes32 current = offers.live(b.venue, b.slot);
        if (current != bytes32(0)) _expectEnd(current, true);
        vm.prank(operators[_venue(b.venue)]);
        offers.place(id);
    }

    function _expectEnd(bytes32 id, bool replaced) internal {
        RegentOffers.Bid memory b = _record(id);
        uint256 paid = b.amount;
        if (replaced) {
            uint256 shown = vm.getBlockTimestamp() - b.startsAt;
            if (shown < b.length) paid = (uint256(b.amount) * shown) / b.length;
        }
        uint256 protocolShare = (paid * 1000) / 10_000;
        expectedCredit[b.bidder] += b.amount - paid;
        expectedCredit[payoutOf[id]] += paid - protocolShare;
        expectedRevenue += protocolShare;
    }

    function _terms(bytes32 venueId, bytes32 slot, uint96 amount, uint32 placeWithin)
        internal
        returns (RegentOffers.Terms memory t)
    {
        (,,,, uint96 minimum, uint32 length) = offers.venues(venueId);
        t = RegentOffers.Terms({
            venue: venueId,
            slot: slot,
            lane: uint8(salt % 3),
            wordingHash: keccak256(abi.encode(salt)),
            amount: uint96(bound(amount, minimum, 1_000_000_000_000)),
            length: length,
            placeBy: uint64(vm.getBlockTimestamp() + bound(placeWithin, 1, 2 days)),
            salt: bytes32(++salt)
        });
    }

    /// @dev The bidder signs the bid's USDC authorization and the relayer submits it; the contract
    ///      wallet's signature is made by bidder a's key.
    function _bidAs(uint256 who, RegentOffers.Terms memory t) internal returns (bytes32) {
        address from = bidders[who];
        uint256 validBefore = vm.getBlockTimestamp() + 10 minutes;
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                address(offers),
                t.amount,
                uint256(0),
                validBefore,
                keccak256(abi.encode(address(offers), t))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            keys[who == 3 ? 0 : who], keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash))
        );
        vm.prank(relayer);
        return offers.bid(t, from, 0, validBefore, abi.encodePacked(r, s, v));
    }

    /// @dev A bid's getter answer is the struct's own encoding, so it decodes straight into one.
    function _record(bytes32 id) internal view returns (RegentOffers.Bid memory) {
        (bool ok, bytes memory answer) = address(offers).staticcall(abi.encodeCall(offers.bids, (id)));
        require(ok, "bids read failed");
        return abi.decode(answer, (RegentOffers.Bid));
    }

    function _venue(bytes32 venueId) internal view returns (uint256) {
        return venueId == venueIds[0] ? 0 : 1;
    }
}

/// @title RegentOffersInvariantTest
/// @notice Whatever happens: the contract's USDC is exactly what bids hold, what is owed, the
///         revenue owed and any USDC sent to it directly; every account was credited exactly what
///         the handler's own book says, and the owed amounts add up to `totalOwed`; each bid pays
///         the payout wallet it was made under; and each slot of each venue shows at most its one
///         live placement.
contract RegentOffersInvariantTest is Test {
    OffersTestUSDC internal usdc;
    OffersTestStaking internal staking;
    RegentOffers internal offers;
    OffersHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        address owner = makeAddr("owner");
        usdc = new OffersTestUSDC();
        staking = new OffersTestStaking(usdc);
        offers = new RegentOffers(usdc, staking, 1000, owner);
        handler = new OffersHandler(usdc, staking, offers, owner);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_usdc_held_is_exactly_what_is_accounted_for() public view {
        assertEq(
            usdc.balanceOf(address(offers)),
            offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed() + handler.strayIn()
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_recovering_the_surplus_never_moves_owed_money() public view {
        assertEq(handler.recovered() + handler.strayIn(), handler.strayTotal(), "only stray USDC was recovered");
        assertEq(usdc.balanceOf(handler.rescuer()), handler.recovered(), "the rescuer got only what was recovered");
        assertGe(
            usdc.balanceOf(address(offers)),
            offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed(),
            "every liability is still held"
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_every_account_is_credited_what_the_book_says() public view {
        uint256 owedSum;
        uint256 paidSum;
        uint256 n = handler.accountCount();
        for (uint256 i; i < n; ++i) {
            address account = handler.accounts(i);
            uint256 owed = offers.owed(account);
            owedSum += owed;
            paidSum += handler.paidTo(account);
            assertEq(owed + handler.paidTo(account), handler.expectedCredit(account), "an account's credit");
        }
        assertEq(owedSum, offers.totalOwed(), "sum of owed");
        assertEq(offers.revenueOwed() + handler.pushed(), handler.expectedRevenue(), "staking share");
        assertEq(usdc.balanceOf(address(staking)), handler.pushed(), "staking received");
        assertEq(usdc.allowance(address(offers), address(staking)), 0, "no approval left with staking");
        assertEq(
            handler.deposited(),
            offers.totalCommitted() + offers.totalOwed() + offers.revenueOwed() + paidSum + handler.pushed(),
            "money in vs money out"
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_bids_agree_with_the_records() public view {
        uint256 committed;
        uint256 count = handler.idCount();
        uint256[4] memory showing;
        for (uint256 i; i < count; ++i) {
            bytes32 id = handler.ids(i);
            (, uint96 amount, bytes32 venueId, bytes32 slot, address payout,,,, RegentOffers.Status s) = offers.bids(id);
            assertEq(payout, handler.payoutOf(id), "a bid's payout wallet");
            if (s == RegentOffers.Status.Held || s == RegentOffers.Status.Placed) committed += amount;
            if (s == RegentOffers.Status.Placed) {
                assertEq(offers.live(venueId, slot), id, "a showing bid is its slot's live one");
                uint256 v = venueId == handler.venueIds(0) ? 0 : 1;
                uint256 k = slot == handler.slots(0) ? 0 : 1;
                ++showing[v * 2 + k];
            }
        }
        assertEq(committed, offers.totalCommitted(), "committed");
        for (uint256 v; v < 2; ++v) {
            for (uint256 k; k < 2; ++k) {
                assertLe(showing[v * 2 + k], 1, "one live placement");
                if (showing[v * 2 + k] == 0) {
                    assertEq(offers.live(handler.venueIds(v), handler.slots(k)), bytes32(0), "no stale live id");
                }
            }
        }
    }
}
