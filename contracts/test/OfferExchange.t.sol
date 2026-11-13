// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OfferExchange} from "../src/OfferExchange.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

/// @notice A six-decimal token standing in for USDC, with Circle's blacklist: a frozen address can
///         neither send nor receive.
contract FreezableUSDC is ERC20 {
    mapping(address account => bool) public frozen;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address account, bool frozen_) external {
        frozen[account] = frozen_;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!frozen[from] && !frozen[to], "FROZEN");
        super._update(from, to, value);
    }
}

/// @notice Stands in for the REGENT revenue staking contract: pulls the deposit, records its tag,
///         and can be paused.
contract RecordingStaking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    bool public paused;
    bytes32 public lastSourceTag;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32) external returns (uint256) {
        require(!paused, "PAUSED");
        lastSourceTag = sourceTag;
        require(usdc.transferFrom(msg.sender, address(this), amount), "PULL_FAILED");
        return amount;
    }
}

/// @notice Shared numbers and the books check every suite here uses.
abstract contract OfferExchangeBase is Test {
    uint64 internal constant START = 1_700_000_000;
    uint96 internal constant MIN_RATE = 10;
    uint96 internal constant RATE = 100;
    /// @dev One hour at `RATE`.
    uint96 internal constant BUDGET = RATE * 3600;
    bytes32 internal constant TAG = "offers.exchange";

    OfferExchange internal exchange;

    function _offer(address bidder) internal pure returns (bytes32) {
        return keccak256(abi.encode("offer", bidder));
    }

    /// @dev Every unit the exchange holds is a budget not yet settled, a credit someone may
    ///      withdraw, or revenue owed to staking; nothing else, and nothing missing.
    function _assertBooksBalance(IERC20 token, address[] memory accounts, uint256[] memory spotIds) internal view {
        uint256 books = exchange.revenueOwed();
        for (uint256 i; i < accounts.length; ++i) {
            books += exchange.owed(accounts[i]);
        }
        for (uint256 s; s < spotIds.length; ++s) {
            (OfferExchange.Hold[3] memory holds,) = exchange.spotHolds(spotIds[s]);
            for (uint256 i; i < 3; ++i) {
                books += holds[i].budget;
            }
        }
        assertEq(token.balanceOf(address(exchange)), books);
    }
}

/// @title OfferExchangeTest
/// @notice What the exchange promises: a bid takes a free slot or beats the lowest live rate by 5%,
///         every holder pays its own rate for the seconds it held (at least a minute when it leaves,
///         only the time held when the site removes it), 90% of every charge goes to the site and 10%
///         to REGENT staking, the unspent budget goes back, nothing is lost to rounding, nobody
///         else's frozen wallet can block a bid, and pausing stops only new bids.
contract OfferExchangeTest is OfferExchangeBase {
    FreezableUSDC internal usdc;
    RecordingStaking internal staking;

    address internal owner = makeAddr("owner");
    address internal site = makeAddr("site");
    address internal otherSite = makeAddr("other-site");
    address internal newPayout = makeAddr("new-payout");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");
    address internal stranger = makeAddr("stranger");

    uint256 internal siteId;
    uint256 internal spotId;

    function setUp() public {
        vm.warp(START);
        usdc = new FreezableUSDC();
        staking = new RecordingStaking(IERC20(address(usdc)));
        exchange = new OfferExchange(IERC20(address(usdc)), staking, owner);

        vm.prank(owner);
        siteId = exchange.listSite(site);
        vm.prank(site);
        spotId = exchange.addSpot(siteId, MIN_RATE);
    }

    function _fund(address bidder, uint256 amount) internal {
        usdc.mint(bidder, amount);
        vm.prank(bidder);
        usdc.approve(address(exchange), amount);
    }

    function _bid(address bidder, uint96 rate, uint96 budget) internal returns (uint256 slot) {
        _fund(bidder, budget);
        vm.prank(bidder);
        slot = exchange.bid(spotId, _offer(bidder), rate, budget);
    }

    /// @dev Alice, Bob and Carol take slots 0, 1 and 2 at these rates, each funded for an hour.
    function _fillThree(uint96 aliceRate, uint96 bobRate, uint96 carolRate) internal {
        _bid(alice, aliceRate, aliceRate * 3600);
        _bid(bob, bobRate, bobRate * 3600);
        _bid(carol, carolRate, carolRate * 3600);
    }

    function _hold(uint256 slot) internal view returns (OfferExchange.Hold memory) {
        (OfferExchange.Hold[3] memory holds,) = exchange.spotHolds(spotId);
        return holds[slot];
    }

    function _live(uint256 slot) internal view returns (bool) {
        (, bool[3] memory live) = exchange.spotHolds(spotId);
        return live[slot];
    }

    function _now() internal view returns (uint64) {
        return SafeCast.toUint64(vm.getBlockTimestamp());
    }

    function _booksBalance() internal view {
        address[] memory accounts = new address[](10);
        accounts[0] = site;
        accounts[1] = otherSite;
        accounts[2] = newPayout;
        accounts[3] = alice;
        accounts[4] = bob;
        accounts[5] = carol;
        accounts[6] = dave;
        accounts[7] = eve;
        accounts[8] = stranger;
        accounts[9] = owner;
        uint256[] memory spotIds = new uint256[](1);
        spotIds[0] = spotId;
        _assertBooksBalance(usdc, accounts, spotIds);
    }

    // ---------------------------------------------------------------- set-up and access

    function test_constructor_refusesZeroAddressesAndKeepsTheOwner() public {
        assertEq(exchange.owner(), owner);
        assertEq(exchange.pendingOwner(), address(0));

        vm.expectRevert(OfferExchange.ZeroAddress.selector);
        new OfferExchange(IERC20(address(0)), staking, owner);

        vm.expectRevert(OfferExchange.ZeroAddress.selector);
        new OfferExchange(IERC20(address(usdc)), IRegentRevenueStaking(address(0)), owner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OfferExchange(IERC20(address(usdc)), staking, address(0));
    }

    function test_listSite_isOwnerOnlyAndNumbersFromOne() public {
        assertEq(siteId, 1);
        assertEq(spotId, 1);
        assertEq(exchange.sitePayout(siteId), site);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        exchange.listSite(otherSite);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, site));
        vm.prank(site);
        exchange.listSite(otherSite);

        vm.expectEmit(address(exchange));
        emit OfferExchange.SiteListed(2, otherSite);
        vm.prank(owner);
        assertEq(exchange.listSite(otherSite), 2);
        assertEq(exchange.siteCount(), 2);
    }

    function test_payout_cannotBeZeroOrTheExchange() public {
        vm.startPrank(owner);
        vm.expectRevert(OfferExchange.InvalidPayout.selector);
        exchange.listSite(address(0));
        vm.expectRevert(OfferExchange.InvalidPayout.selector);
        exchange.listSite(address(exchange));
        vm.stopPrank();

        vm.startPrank(site);
        vm.expectRevert(OfferExchange.InvalidPayout.selector);
        exchange.setPayout(siteId, address(0));
        vm.expectRevert(OfferExchange.InvalidPayout.selector);
        exchange.setPayout(siteId, address(exchange));
        vm.stopPrank();
    }

    function test_aSiteManagesOnlyItsOwnSpotsAndPayout() public {
        vm.prank(owner);
        exchange.listSite(otherSite);

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(stranger);
        exchange.addSpot(siteId, MIN_RATE);

        // The owner lists sites but does not run them.
        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(owner);
        exchange.addSpot(siteId, MIN_RATE);

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(otherSite);
        exchange.addSpot(siteId, MIN_RATE);

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(site);
        exchange.addSpot(99, MIN_RATE);

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(otherSite);
        exchange.setPayout(siteId, otherSite);

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(owner);
        exchange.setPayout(siteId, owner);

        vm.expectEmit(address(exchange));
        emit OfferExchange.SpotAdded(2, siteId, 20);
        vm.prank(site);
        assertEq(exchange.addSpot(siteId, 20), 2);
        (uint256 spotSite, uint96 minRate) = exchange.spots(2);
        assertEq(spotSite, siteId);
        assertEq(minRate, 20);
        assertEq(exchange.spotCount(), 2);
    }

    function test_addSpot_refusesAZeroMinimumRate() public {
        vm.expectRevert(OfferExchange.ZeroRate.selector);
        vm.prank(site);
        exchange.addSpot(siteId, 0);
    }

    function test_setPayout_movesOnlyLaterEarnings() public {
        _bid(alice, RATE, BUDGET);
        skip(100);
        vm.prank(site);
        exchange.remove(spotId, 0);
        assertEq(exchange.owed(site), 9_000);

        vm.expectEmit(address(exchange));
        emit OfferExchange.PayoutChanged(siteId, site, newPayout);
        vm.prank(site);
        exchange.setPayout(siteId, newPayout);
        assertEq(exchange.sitePayout(siteId), newPayout);

        _bid(bob, RATE, BUDGET);
        skip(100);
        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(site);
        exchange.remove(spotId, 0);

        vm.prank(newPayout);
        exchange.remove(spotId, 0);
        assertEq(exchange.owed(newPayout), 9_000);
        assertEq(exchange.owed(site), 9_000);

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(site);
        exchange.addSpot(siteId, MIN_RATE);
        _booksBalance();
    }

    // ---------------------------------------------------------------- bidding

    function test_bid_takesAFreeSlotAndPullsTheBudget() public {
        _fund(alice, BUDGET);

        vm.expectEmit(address(exchange));
        emit OfferExchange.BidPlaced(spotId, alice, _offer(alice), 0, RATE, BUDGET, START + 3600);
        vm.prank(alice);
        assertEq(exchange.bid(spotId, _offer(alice), RATE, BUDGET), 0);

        assertEq(usdc.balanceOf(address(exchange)), BUDGET);
        assertEq(usdc.balanceOf(alice), 0);

        OfferExchange.Hold memory hold = _hold(0);
        assertEq(hold.bidder, alice);
        assertEq(hold.start, START);
        assertEq(hold.offerId, _offer(alice));
        assertEq(hold.rate, RATE);
        assertEq(hold.budget, BUDGET);
        assertEq(hold.endsAt, START + 3600);
        assertTrue(_live(0));
        assertFalse(_live(1));
        assertFalse(_live(2));
        _booksBalance();
    }

    function test_bid_fillsThreeSlotsThenAnEqualRateCannotGetIn() public {
        assertEq(_bid(alice, RATE, BUDGET), 0);
        assertEq(_bid(bob, RATE, BUDGET), 1);
        assertEq(_bid(carol, RATE, BUDGET), 2);
        assertTrue(_live(0) && _live(1) && _live(2));
        assertEq(usdc.balanceOf(address(exchange)), 3 * uint256(BUDGET));

        _fund(dave, BUDGET);
        vm.expectRevert(OfferExchange.BidTooLow.selector);
        vm.prank(dave);
        exchange.bid(spotId, _offer(dave), RATE, BUDGET);
    }

    function test_bid_mustBeatTheLowestRateByFivePercent() public {
        _fillThree(2000, 1000, 3000);
        _fund(dave, 1050 * 3600);

        // One unit per second short of 5% above Bob's 1000.
        vm.expectRevert(OfferExchange.BidTooLow.selector);
        vm.prank(dave);
        exchange.bid(spotId, _offer(dave), 1049, 1049 * 3600);

        vm.prank(dave);
        assertEq(exchange.bid(spotId, _offer(dave), 1050, 1050 * 3600), 1);

        assertEq(_hold(0).bidder, alice);
        assertEq(_hold(1).bidder, dave);
        assertEq(_hold(2).bidder, carol);
        assertEq(usdc.balanceOf(dave), 0);
        _booksBalance();
    }

    function test_bid_refusesZeroAndTooSmallInputs() public {
        _fund(alice, BUDGET);
        vm.startPrank(alice);

        vm.expectRevert(OfferExchange.UnknownSpot.selector);
        exchange.bid(0, _offer(alice), RATE, BUDGET);
        vm.expectRevert(OfferExchange.UnknownSpot.selector);
        exchange.bid(99, _offer(alice), RATE, BUDGET);

        vm.expectRevert(OfferExchange.ZeroOffer.selector);
        exchange.bid(spotId, bytes32(0), RATE, BUDGET);

        vm.expectRevert(OfferExchange.RateTooLow.selector);
        exchange.bid(spotId, _offer(alice), 0, BUDGET);
        vm.expectRevert(OfferExchange.RateTooLow.selector);
        exchange.bid(spotId, _offer(alice), MIN_RATE - 1, BUDGET);

        vm.expectRevert(OfferExchange.BudgetTooSmall.selector);
        exchange.bid(spotId, _offer(alice), RATE, 0);
        vm.expectRevert(OfferExchange.BudgetTooSmall.selector);
        exchange.bid(spotId, _offer(alice), RATE, RATE * 60 - 1);

        // Exactly the minimum rate and exactly a minute of budget are enough.
        assertEq(exchange.bid(spotId, _offer(alice), RATE, RATE * 60), 0);
        assertEq(exchange.bid(spotId, _offer(alice), MIN_RATE, MIN_RATE * 60), 1);
        vm.stopPrank();

        assertEq(_hold(0).endsAt, START + 60);
        assertEq(_hold(1).endsAt, START + 60);
    }

    function test_bid_refusesAHoldTooLongToRecord() public {
        uint96 budget = type(uint96).max;
        _fund(alice, budget);

        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 64, uint256(START) + budget / MIN_RATE
            )
        );
        vm.prank(alice);
        exchange.bid(spotId, _offer(alice), MIN_RATE, budget);
    }

    function test_tie_theEarlierHolderKeepsItsSlot() public {
        _bid(alice, 1000, 1000 * 60); // runs out after a minute
        _bid(bob, 3000, 3000 * 3600);
        _bid(carol, 1000, 1000 * 3600);
        skip(60);

        // Dave takes Alice's run-out slot 0 a minute after Carol took slot 2 at the same rate.
        assertEq(_bid(dave, 1000, 1000 * 3600), 0);

        // Carol was there first, so the later Dave is the one replaced, though Carol's slot is higher.
        assertEq(_bid(eve, 1050, 1050 * 3600), 0);
        assertEq(_hold(0).bidder, eve);
        assertEq(_hold(2).bidder, carol);
        _booksBalance();
    }

    function test_tie_inTheSameSecondTheHigherSlotIsTaken() public {
        _fillThree(1000, 1000, 2000);
        assertEq(_bid(dave, 1050, 1050 * 3600), 1);
        assertEq(_hold(0).bidder, alice);
        assertEq(_hold(1).bidder, dave);
    }

    // ---------------------------------------------------------------- settlement

    function test_overtake_chargesTheReplacedHoldForTheTimeItHeld() public {
        _bid(alice, 1000, 1000 * 3600 + 7);
        _bid(bob, 2000, 2000 * 3600);
        _bid(carol, 3000, 3000 * 3600);
        skip(600);
        _fund(dave, 1050 * 3600);

        // 600 seconds at 1000: charged 600_000, of which 60_000 revenue and 540_000 to the site.
        vm.expectEmit(address(exchange));
        emit OfferExchange.Overtaken(spotId, alice, dave, 0, 1050, 600_000, 3_000_007);
        vm.expectEmit(address(exchange));
        emit OfferExchange.BidPlaced(spotId, dave, _offer(dave), 0, 1050, 1050 * 3600, START + 600 + 3600);
        vm.prank(dave);
        exchange.bid(spotId, _offer(dave), 1050, 1050 * 3600);

        assertEq(exchange.owed(alice), 3_000_007);
        assertEq(exchange.owed(site), 540_000);
        assertEq(exchange.revenueOwed(), 60_000);
        assertEq(_hold(0).bidder, dave);
        assertEq(_hold(0).start, START + 600);
        _booksBalance();
    }

    function test_overtake_inTheSameSecondChargesNothing() public {
        _fillThree(1000, 2000, 3000);
        _bid(dave, 1050, 1050 * 3600);
        assertEq(exchange.owed(alice), 1000 * 3600);
        assertEq(exchange.owed(site), 0);
        assertEq(exchange.revenueOwed(), 0);
        _booksBalance();
    }

    function test_runOut_theSlotIsFreeAndTheNextBidSettlesIt() public {
        _bid(alice, RATE, RATE * 60 + 50); // a minute, with 50 units left over
        _bid(bob, RATE, BUDGET);
        _bid(carol, RATE, BUDGET);

        skip(59);
        assertTrue(_live(0));
        skip(1);
        assertFalse(_live(0));
        assertEq(_hold(0).bidder, alice);

        // A free slot needs no step: the spot's minimum rate takes it.
        _fund(dave, MIN_RATE * 60);
        vm.expectEmit(address(exchange));
        emit OfferExchange.HoldEnded(spotId, alice, 0, OfferExchange.EndReason.RanOut, 6_000, 50);
        vm.expectEmit(address(exchange));
        emit OfferExchange.BidPlaced(spotId, dave, _offer(dave), 0, MIN_RATE, MIN_RATE * 60, START + 120);
        vm.prank(dave);
        assertEq(exchange.bid(spotId, _offer(dave), MIN_RATE, MIN_RATE * 60), 0);

        assertEq(exchange.owed(alice), 50);
        assertEq(exchange.owed(site), 5_400);
        assertEq(exchange.revenueOwed(), 600);
        _booksBalance();
    }

    function test_settle_anyoneSettlesARunOutHoldOnce() public {
        _bid(alice, RATE, RATE * 60 + 50);

        vm.expectRevert(OfferExchange.NothingToSettle.selector);
        vm.prank(stranger);
        exchange.settle(spotId, 0);

        skip(60);
        vm.expectEmit(address(exchange));
        emit OfferExchange.HoldEnded(spotId, alice, 0, OfferExchange.EndReason.RanOut, 6_000, 50);
        vm.prank(stranger);
        exchange.settle(spotId, 0);

        assertEq(exchange.owed(alice), 50);
        assertEq(exchange.owed(site), 5_400);
        assertEq(exchange.revenueOwed(), 600);
        assertEq(_hold(0).bidder, address(0));

        vm.expectRevert(OfferExchange.NothingToSettle.selector);
        exchange.settle(spotId, 0);
        vm.expectRevert(OfferExchange.NothingToSettle.selector);
        exchange.settle(spotId, 2);
        _booksBalance();
    }

    function test_leave_chargesAtLeastTheMinimumHold() public {
        _bid(alice, RATE, BUDGET);
        skip(10);

        // Ten seconds held, sixty charged: taking a slot and leaving at once is not free.
        vm.expectEmit(address(exchange));
        emit OfferExchange.HoldEnded(spotId, alice, 0, OfferExchange.EndReason.Left, 6_000, 354_000);
        vm.prank(alice);
        exchange.leave(spotId, 0);

        assertEq(exchange.owed(alice), 354_000);
        assertEq(exchange.owed(site), 5_400);
        assertEq(exchange.revenueOwed(), 600);
        assertFalse(_live(0));
        assertEq(_hold(0).bidder, address(0));
        _booksBalance();
    }

    function test_leave_pastTheMinimumChargesTheTimeHeld() public {
        _bid(alice, RATE, BUDGET);
        skip(600);
        vm.prank(alice);
        exchange.leave(spotId, 0);

        assertEq(exchange.owed(alice), 300_000);
        assertEq(exchange.owed(site), 54_000);
        assertEq(exchange.revenueOwed(), 6_000);
    }

    function test_leave_onlyTheHolderOfALiveHold() public {
        _bid(alice, RATE, RATE * 60);

        vm.expectRevert(OfferExchange.NotHolder.selector);
        vm.prank(bob);
        exchange.leave(spotId, 0);

        vm.expectRevert(OfferExchange.NotHolder.selector);
        vm.prank(bob);
        exchange.leave(spotId, 1);

        skip(60);
        vm.expectRevert(OfferExchange.NotLive.selector);
        vm.prank(alice);
        exchange.leave(spotId, 0);
    }

    function test_remove_bySiteChargesOnlyTheTimeHeld() public {
        _bid(alice, RATE, BUDGET);
        skip(10);

        vm.expectEmit(address(exchange));
        emit OfferExchange.HoldEnded(spotId, alice, 0, OfferExchange.EndReason.Removed, 1_000, 359_000);
        vm.prank(site);
        exchange.remove(spotId, 0);

        assertEq(exchange.owed(alice), 359_000);
        assertEq(exchange.owed(site), 900);
        assertEq(exchange.revenueOwed(), 100);

        // Removed in the second it arrived: no minimum, nothing charged.
        _bid(bob, RATE, BUDGET);
        vm.prank(site);
        exchange.remove(spotId, 0);
        assertEq(exchange.owed(bob), BUDGET);
        _booksBalance();
    }

    function test_remove_onlyTheSiteOfALiveHold() public {
        vm.prank(owner);
        exchange.listSite(otherSite);
        _bid(alice, RATE, BUDGET);

        address[4] memory refused = [stranger, alice, owner, otherSite];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(OfferExchange.NotSite.selector);
            vm.prank(refused[i]);
            exchange.remove(spotId, 0);
        }

        vm.expectRevert(OfferExchange.NotSite.selector);
        vm.prank(site);
        exchange.remove(99, 0);

        vm.expectRevert(OfferExchange.NotLive.selector);
        vm.prank(site);
        exchange.remove(spotId, 1);
    }

    function test_slotIndexAboveTwoIsRefused() public {
        _bid(alice, RATE, BUDGET);

        vm.expectRevert(OfferExchange.UnknownSlot.selector);
        vm.prank(alice);
        exchange.leave(spotId, 3);

        vm.expectRevert(OfferExchange.UnknownSlot.selector);
        vm.prank(site);
        exchange.remove(spotId, 3);

        vm.expectRevert(OfferExchange.UnknownSlot.selector);
        exchange.settle(spotId, 3);
    }

    // ---------------------------------------------------------------- money out

    function test_withdraw_sendsAllOwedOnce() public {
        vm.expectRevert(OfferExchange.NothingOwed.selector);
        vm.prank(alice);
        exchange.withdraw();

        _bid(alice, RATE, BUDGET);
        skip(10);
        vm.prank(alice);
        exchange.leave(spotId, 0);

        vm.expectEmit(address(exchange));
        emit OfferExchange.Withdrawn(alice, 354_000);
        vm.prank(alice);
        assertEq(exchange.withdraw(), 354_000);
        assertEq(usdc.balanceOf(alice), 354_000);
        assertEq(exchange.owed(alice), 0);

        vm.expectRevert(OfferExchange.NothingOwed.selector);
        vm.prank(alice);
        exchange.withdraw();

        vm.prank(site);
        assertEq(exchange.withdraw(), 5_400);
        _booksBalance();
    }

    function test_pushRevenue_depositsAllOwedTaggedForAnyCaller() public {
        _bid(alice, RATE, BUDGET);
        skip(10);
        vm.prank(alice);
        exchange.leave(spotId, 0);

        vm.expectEmit(address(exchange));
        emit OfferExchange.RevenuePushed(stranger, 600);
        vm.prank(stranger);
        assertEq(exchange.pushRevenue(), 600);

        assertEq(usdc.balanceOf(address(staking)), 600);
        assertEq(staking.lastSourceTag(), TAG);
        assertEq(exchange.revenueOwed(), 0);

        vm.expectRevert(OfferExchange.NothingOwed.selector);
        exchange.pushRevenue();
        _booksBalance();
    }

    function test_aPausedStakingContractHoldsUpOnlyThePush() public {
        staking.setPaused(true);
        _bid(alice, RATE, BUDGET);
        skip(10);
        vm.prank(alice);
        exchange.leave(spotId, 0);
        vm.prank(alice);
        exchange.withdraw();

        vm.expectRevert(bytes("PAUSED"));
        exchange.pushRevenue();
        assertEq(exchange.revenueOwed(), 600);
        _bid(bob, RATE, BUDGET);

        staking.setPaused(false);
        exchange.pushRevenue();
        assertEq(usdc.balanceOf(address(staking)), 600);
        _booksBalance();
    }

    // ---------------------------------------------------------------- pause

    function test_pause_stopsOnlyNewBids() public {
        _bid(alice, RATE, BUDGET);
        _bid(bob, RATE, RATE * 60);
        _bid(carol, RATE, BUDGET);

        vm.expectEmit(address(exchange));
        emit OfferExchange.PauseSet(true);
        vm.prank(owner);
        exchange.setPaused(true);
        assertTrue(exchange.paused());

        _fund(dave, BUDGET);
        vm.expectRevert(OfferExchange.BidsPaused.selector);
        vm.prank(dave);
        exchange.bid(spotId, _offer(dave), RATE, BUDGET);

        // Leaving, removal, settlement, withdrawal and the push all carry on.
        vm.prank(alice);
        exchange.leave(spotId, 0);
        vm.prank(site);
        exchange.remove(spotId, 2);
        skip(60);
        exchange.settle(spotId, 1);
        vm.prank(alice);
        exchange.withdraw();
        vm.prank(site);
        exchange.withdraw();
        exchange.pushRevenue();

        vm.prank(owner);
        exchange.setPaused(false);
        vm.prank(dave);
        exchange.bid(spotId, _offer(dave), RATE, BUDGET);
        _booksBalance();
    }

    function test_setPaused_isOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        exchange.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, site));
        vm.prank(site);
        exchange.setPaused(true);
    }

    // ---------------------------------------------------------------- frozen wallets

    function test_aFrozenSiteBlocksOnlyItsOwnWithdrawal() public {
        _fillThree(1000, 2000, 3000);
        usdc.freeze(site, true);
        skip(100);

        _bid(dave, 1050, 1050 * 3600);
        vm.prank(bob);
        exchange.leave(spotId, 1);
        assertEq(exchange.owed(site), 90_000 + 180_000);

        vm.expectRevert(bytes("FROZEN"));
        vm.prank(site);
        exchange.withdraw();

        vm.prank(alice);
        assertEq(exchange.withdraw(), 3_500_000);
        vm.prank(bob);
        assertEq(exchange.withdraw(), 7_000_000);
        exchange.pushRevenue();
        _bid(eve, 1000, 1000 * 3600);

        usdc.freeze(site, false);
        vm.prank(site);
        assertEq(exchange.withdraw(), 270_000);
        _booksBalance();
    }

    function test_aFrozenBidderCannotBlockAnOvertake() public {
        _fillThree(1000, 2000, 3000);
        usdc.freeze(alice, true);
        skip(100);

        _bid(dave, 1050, 1050 * 3600);
        assertEq(exchange.owed(alice), 3_500_000);

        vm.expectRevert(bytes("FROZEN"));
        vm.prank(alice);
        exchange.withdraw();

        vm.prank(site);
        assertEq(exchange.withdraw(), 90_000);

        usdc.freeze(alice, false);
        vm.prank(alice);
        assertEq(exchange.withdraw(), 3_500_000);
        _booksBalance();
    }

    // ---------------------------------------------------------------- properties

    /// @dev Whatever the rate, budget and time held, the overtaken holder pays exactly its rate for
    ///      the seconds it held, and the site, the revenue and the refund sum to its budget.
    function testFuzz_overtake_chargesExactlyTheTimeHeld(uint256 rate, uint256 funded, uint256 dust, uint256 elapsed)
        public
    {
        rate = bound(rate, MIN_RATE, 1e12);
        funded = bound(funded, 60, 365 days);
        dust = bound(dust, 0, rate - 1);
        elapsed = bound(elapsed, 0, funded - 1);
        uint96 budget = SafeCast.toUint96(rate * funded + dust);

        _bid(alice, SafeCast.toUint96(rate), budget);
        _bid(bob, SafeCast.toUint96(rate * 2), SafeCast.toUint96(rate * 2 * funded));
        _bid(carol, SafeCast.toUint96(rate * 3), SafeCast.toUint96(rate * 3 * funded));
        skip(elapsed);

        uint256 step = (rate * 10_500 + 9_999) / 10_000;
        assertEq(_bid(dave, SafeCast.toUint96(step), SafeCast.toUint96(step * 60)), 0);

        uint256 charged = rate * elapsed;
        assertEq(exchange.owed(alice), budget - charged);
        assertEq(exchange.revenueOwed(), (charged * 1000) / 10_000);
        assertEq(exchange.owed(site) + exchange.revenueOwed(), charged);
        _booksBalance();
    }

    /// @dev A bid against three live holds takes the lowest one's slot exactly when it is at least
    ///      5% higher, and otherwise changes nothing.
    function testFuzz_bid_takesTheLowestOnlyWithAFivePercentStep(uint256 r0, uint256 r1, uint256 r2, uint256 rNew)
        public
    {
        uint256[3] memory rates = [bound(r0, MIN_RATE, 1e12), bound(r1, MIN_RATE, 1e12), bound(r2, MIN_RATE, 1e12)];
        rNew = bound(rNew, MIN_RATE, 1e12);
        _fillThree(SafeCast.toUint96(rates[0]), SafeCast.toUint96(rates[1]), SafeCast.toUint96(rates[2]));

        // All three arrived in the same second, so among equal lowest rates the higher slot goes.
        uint256 lowest;
        for (uint256 i = 1; i < 3; ++i) {
            if (rates[i] <= rates[lowest]) lowest = i;
        }

        _fund(dave, rNew * 3600);
        if (rNew * 10_000 < rates[lowest] * 10_500) {
            vm.expectRevert(OfferExchange.BidTooLow.selector);
            vm.prank(dave);
            exchange.bid(spotId, _offer(dave), SafeCast.toUint96(rNew), SafeCast.toUint96(rNew * 3600));
        } else {
            vm.prank(dave);
            uint256 slot = exchange.bid(spotId, _offer(dave), SafeCast.toUint96(rNew), SafeCast.toUint96(rNew * 3600));
            assertEq(slot, lowest);
            assertEq(_hold(slot).bidder, dave);
        }
        _booksBalance();
    }

    /// @dev Leaving charges the seconds held, never fewer than a minute, and loses nothing.
    function testFuzz_leave_neverChargesLessThanAMinute(uint256 rate, uint256 funded, uint256 elapsed) public {
        rate = bound(rate, MIN_RATE, 1e12);
        funded = bound(funded, 60, 365 days);
        elapsed = bound(elapsed, 0, funded - 1);
        uint96 budget = SafeCast.toUint96(rate * funded);

        _bid(alice, SafeCast.toUint96(rate), budget);
        skip(elapsed);
        vm.prank(alice);
        exchange.leave(spotId, 0);

        uint256 charged = rate * (elapsed < 60 ? 60 : elapsed);
        assertEq(exchange.owed(alice), budget - charged);
        assertEq(exchange.owed(site) + exchange.revenueOwed(), charged);
        _booksBalance();
    }

    /// @dev A hold that runs out is charged its whole funded time; the rounding left over from
    ///      `budget / rate` goes back to the bidder, never stuck.
    function testFuzz_runOut_returnsTheRoundingToTheBidder(uint256 rate, uint256 funded, uint256 dust, uint256 late)
        public
    {
        rate = bound(rate, MIN_RATE, 1e12);
        funded = bound(funded, 60, 365 days);
        dust = bound(dust, 0, rate - 1);
        late = bound(late, 0, 365 days);
        uint96 budget = SafeCast.toUint96(rate * funded + dust);

        _bid(alice, SafeCast.toUint96(rate), budget);
        skip(funded + late);
        exchange.settle(spotId, 0);

        assertEq(exchange.owed(alice), dust);
        assertEq(exchange.owed(site) + exchange.revenueOwed(), rate * funded);
        assertEq(exchange.owed(site), rate * funded - (rate * funded * 1000) / 10_000);
        _booksBalance();
    }
}

/// @notice A hook a token calls on its holder, like an ERC-777 send or receive hook.
interface ITransferHook {
    function onTokenTransfer() external;
}

/// @notice A USDC stand-in that calls its hooked holder back before every transfer out of it and
///         after every transfer into it.
contract HookUSDC is FreezableUSDC {
    address public hooked;

    function hook(address account) external {
        hooked = account;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from == hooked) ITransferHook(from).onTokenTransfer();
        super._update(from, to, value);
        if (to != address(0) && to == hooked) ITransferHook(to).onTokenTransfer();
    }
}

/// @notice A bidder that calls back into the exchange from inside a token transfer, once.
contract Reenterer is ITransferHook {
    enum Attack {
        Withdraw,
        Leave
    }

    OfferExchange internal immutable exchange;
    bool internal armed;
    Attack internal attack;
    uint256 internal spotId;
    uint256 internal slot;
    bytes public reentryError;

    constructor(OfferExchange exchange_, IERC20 token) {
        exchange = exchange_;
        token.approve(address(exchange_), type(uint256).max);
    }

    function arm(Attack attack_, uint256 spotId_, uint256 slot_) external {
        armed = true;
        attack = attack_;
        spotId = spotId_;
        slot = slot_;
    }

    function bid(uint256 spotId_, uint96 rate, uint96 budget) external returns (uint256) {
        return exchange.bid(spotId_, keccak256("reenterer"), rate, budget);
    }

    function withdraw() external returns (uint256) {
        return exchange.withdraw();
    }

    function onTokenTransfer() external {
        if (!armed) return;
        armed = false;
        if (attack == Attack.Withdraw) {
            try exchange.withdraw() {}
            catch (bytes memory reason) {
                reentryError = reason;
            }
        } else {
            try exchange.leave(spotId, slot) {}
            catch (bytes memory reason) {
                reentryError = reason;
            }
        }
    }
}

/// @title OfferExchangeReentrancyTest
/// @notice A token that calls back mid-transfer gains nothing: credit is cleared before it is sent,
///         and a bid's budget arrives before its hold exists.
contract OfferExchangeReentrancyTest is OfferExchangeBase {
    HookUSDC internal token;
    Reenterer internal attacker;
    address internal owner = makeAddr("owner");
    address internal site = makeAddr("site");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    uint256 internal spotId;

    function setUp() public {
        vm.warp(START);
        token = new HookUSDC();
        exchange = new OfferExchange(IERC20(address(token)), new RecordingStaking(IERC20(address(token))), owner);
        vm.prank(owner);
        uint256 siteId = exchange.listSite(site);
        vm.prank(site);
        spotId = exchange.addSpot(siteId, MIN_RATE);

        attacker = new Reenterer(exchange, IERC20(address(token)));
        token.hook(address(attacker));
    }

    function _bid(address bidder, uint96 rate, uint96 budget) internal {
        token.mint(bidder, budget);
        vm.startPrank(bidder);
        token.approve(address(exchange), budget);
        exchange.bid(spotId, _offer(bidder), rate, budget);
        vm.stopPrank();
    }

    function _books() internal view {
        address[] memory accounts = new address[](4);
        accounts[0] = site;
        accounts[1] = alice;
        accounts[2] = bob;
        accounts[3] = address(attacker);
        uint256[] memory spotIds = new uint256[](1);
        spotIds[0] = spotId;
        _assertBooksBalance(IERC20(address(token)), accounts, spotIds);
    }

    function test_aReentrantWithdrawPaysNothingTwice() public {
        token.mint(address(attacker), 1000 * 3600);
        attacker.bid(spotId, 1000, 1000 * 3600);
        _bid(alice, 2000, 2000 * 3600);
        _bid(bob, 3000, 3000 * 3600);
        skip(100);
        _bid(carol, 1050, 1050 * 3600);
        assertEq(exchange.owed(address(attacker)), 3_500_000);

        attacker.arm(Reenterer.Attack.Withdraw, 0, 0);
        assertEq(attacker.withdraw(), 3_500_000);

        assertEq(attacker.reentryError(), abi.encodeWithSelector(OfferExchange.NothingOwed.selector));
        assertEq(token.balanceOf(address(attacker)), 3_500_000);
        assertEq(exchange.owed(address(attacker)), 0);
        _books();
    }

    function test_aCallBackDuringTheBidPullFindsNoHoldYet() public {
        token.mint(address(attacker), BUDGET);
        attacker.arm(Reenterer.Attack.Leave, spotId, 0);
        assertEq(attacker.bid(spotId, RATE, BUDGET), 0);

        // The callback ran before the budget moved, and the hold did not exist yet to leave.
        assertEq(attacker.reentryError(), abi.encodeWithSelector(OfferExchange.NotHolder.selector));
        (OfferExchange.Hold[3] memory holds, bool[3] memory live) = exchange.spotHolds(spotId);
        assertEq(holds[0].bidder, address(attacker));
        assertTrue(live[0]);
        assertEq(token.balanceOf(address(exchange)), BUDGET);
        _books();
    }
}

/// @notice Drives the exchange through random bids, leaves, removals, settlements, withdrawals,
///         pushes, payout changes, freezes and the passing of time.
contract ExchangeHandler is Test {
    uint96 internal constant MIN_RATE = 10;

    OfferExchange internal immutable exchange;
    FreezableUSDC internal immutable usdc;
    address[] internal bidders;
    address[] internal payouts;
    uint256[] internal siteIds;
    uint256[] internal spotIds;

    /// @notice How often each path took effect in this run, so the suite can show every path ran.
    mapping(string path => uint256 count) public reached;

    constructor(
        OfferExchange exchange_,
        FreezableUSDC usdc_,
        address[] memory bidders_,
        address[] memory payouts_,
        uint256[] memory siteIds_,
        uint256[] memory spotIds_
    ) {
        exchange = exchange_;
        usdc = usdc_;
        bidders = bidders_;
        payouts = payouts_;
        siteIds = siteIds_;
        spotIds = spotIds_;
    }

    function bid(uint256 bidderSeed, uint256 spotSeed, uint256 rate, uint256 funded, uint256 dust) external {
        _bid(bidderSeed, spotIds[spotSeed % spotIds.length], bound(rate, MIN_RATE, 1e9), funded, dust);
    }

    /// @dev Fills the spot's free slots at its minimum rate, then bids between 10% under and 50%
    ///      over its lowest live rate, so every run meets full spots and bids on both sides of the
    ///      5% step. A random sequence alone rarely fills a spot.
    function overtake(uint256 bidderSeed, uint256 spotSeed, uint256 step, uint256 funded, uint256 dust) external {
        bidderSeed %= bidders.length;
        uint256 spotId = spotIds[spotSeed % spotIds.length];
        (, uint96 minRate) = exchange.spots(spotId);
        for (uint256 i; i < 3; ++i) {
            (, bool[3] memory filled) = exchange.spotHolds(spotId);
            if (!(filled[0] && filled[1] && filled[2])) _bid(bidderSeed + i, spotId, minRate, funded, dust);
        }

        (OfferExchange.Hold[3] memory holds, bool[3] memory live) = exchange.spotHolds(spotId);
        if (!(live[0] && live[1] && live[2])) return;
        uint256 lowest = holds[0].rate;
        if (holds[1].rate < lowest) lowest = holds[1].rate;
        if (holds[2].rate < lowest) lowest = holds[2].rate;
        uint256 rate = (lowest * bound(step, 9_000, 15_000)) / 10_000 + 1;
        if (rate <= 1e12) _bid(bidderSeed + 3, spotId, rate, funded, dust);
    }

    /// @dev A frozen bidder cannot pay in, so the first bidder from the seed that is not frozen bids.
    function _bid(uint256 bidderSeed, uint256 spotId, uint256 rate, uint256 funded, uint256 dust) internal {
        address bidder;
        for (uint256 i; i < bidders.length && bidder == address(0); ++i) {
            address candidate = bidders[(bidderSeed % bidders.length + i) % bidders.length];
            if (!usdc.frozen(candidate)) bidder = candidate;
        }
        if (bidder == address(0)) return;
        uint256 budget = rate * bound(funded, 60, 7 days) + bound(dust, 0, rate - 1);
        (OfferExchange.Hold[3] memory before, bool[3] memory live) = exchange.spotHolds(spotId);

        usdc.mint(bidder, budget);
        vm.startPrank(bidder);
        usdc.approve(address(exchange), budget);
        try exchange.bid(
            spotId, keccak256(abi.encode(bidder)), SafeCast.toUint96(rate), SafeCast.toUint96(budget)
        ) returns (
            uint256 slot
        ) {
            if (live[slot]) reached["overtake"] += 1;
            else if (before[slot].bidder != address(0)) reached["reuse run-out slot"] += 1;
            else reached["empty slot"] += 1;
        } catch {
            reached["bid too low"] += 1;
        }
        vm.stopPrank();
    }

    /// @dev Either the slot's own holder leaves or its site removes it. One action for both, so
    ///      holds are taken down about as often as bids arrive and spots still fill up.
    function takeDown(bool bySite, uint256 spotSeed, uint256 slot) external {
        uint256 spotId = spotIds[spotSeed % spotIds.length];
        slot %= 3;
        if (bySite) {
            (uint256 siteId,) = exchange.spots(spotId);
            vm.prank(exchange.sitePayout(siteId));
            try exchange.remove(spotId, slot) {
                reached["remove"] += 1;
            } catch {}
        } else {
            (OfferExchange.Hold[3] memory holds,) = exchange.spotHolds(spotId);
            vm.prank(holds[slot].bidder);
            try exchange.leave(spotId, slot) {
                reached["leave"] += 1;
            } catch {}
        }
    }

    /// @dev Settles the first run-out hold in the spot, if there is one.
    function settle(uint256 spotSeed) external {
        uint256 spotId = spotIds[spotSeed % spotIds.length];
        (OfferExchange.Hold[3] memory holds, bool[3] memory live) = exchange.spotHolds(spotId);
        for (uint256 slot; slot < 3; ++slot) {
            if (holds[slot].bidder != address(0) && !live[slot]) {
                exchange.settle(spotId, slot);
                reached["settle"] += 1;
                return;
            }
        }
    }

    function withdraw(uint256 accountSeed) external {
        address account = accountSeed % 2 == 0
            ? bidders[(accountSeed / 2) % bidders.length]
            : payouts[(accountSeed / 2) % payouts.length];
        vm.prank(account);
        try exchange.withdraw() {
            reached["withdraw"] += 1;
        } catch {}
    }

    function pushRevenue() external {
        try exchange.pushRevenue() {
            reached["push"] += 1;
        } catch {}
    }

    function setPayout(uint256 siteSeed, uint256 payoutSeed) external {
        uint256 siteId = siteIds[siteSeed % siteIds.length];
        vm.prank(exchange.sitePayout(siteId));
        exchange.setPayout(siteId, payouts[payoutSeed % payouts.length]);
    }

    function freeze(uint256 accountSeed, bool frozen) external {
        address account = accountSeed % 2 == 0
            ? bidders[(accountSeed / 2) % bidders.length]
            : payouts[(accountSeed / 2) % payouts.length];
        usdc.freeze(account, frozen);
    }

    function wait(uint256 seconds_) external {
        skip(bound(seconds_, 0, 1 days));
    }
}

/// @title OfferExchangeInvariantTest
/// @notice Whatever happens, the USDC the exchange holds is exactly the unsettled budgets, the
///         credit owed to every address and the revenue owed; and every hold runs for exactly as
///         many whole seconds as its budget pays for.
contract OfferExchangeInvariantTest is OfferExchangeBase {
    FreezableUSDC internal usdc;
    ExchangeHandler internal handler;
    address[] internal accounts;
    uint256[] internal spotIds;

    function setUp() public {
        vm.warp(START);
        usdc = new FreezableUSDC();
        address owner = makeAddr("owner");
        exchange = new OfferExchange(IERC20(address(usdc)), new RecordingStaking(IERC20(address(usdc))), owner);

        address[] memory bidders = new address[](4);
        address[] memory payouts = new address[](3);
        for (uint256 i; i < bidders.length; ++i) {
            bidders[i] = makeAddr(string.concat("bidder-", vm.toString(i)));
            accounts.push(bidders[i]);
        }
        for (uint256 i; i < payouts.length; ++i) {
            payouts[i] = makeAddr(string.concat("payout-", vm.toString(i)));
            accounts.push(payouts[i]);
        }

        uint256[] memory siteIds = new uint256[](2);
        vm.startPrank(owner);
        siteIds[0] = exchange.listSite(payouts[0]);
        siteIds[1] = exchange.listSite(payouts[1]);
        vm.stopPrank();

        vm.prank(payouts[0]);
        spotIds.push(exchange.addSpot(siteIds[0], MIN_RATE));
        vm.prank(payouts[1]);
        spotIds.push(exchange.addSpot(siteIds[1], 1000));

        handler = new ExchangeHandler(exchange, usdc, bidders, payouts, siteIds, spotIds);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_heldUsdcEqualsTheBooks() public view {
        _assertBooksBalance(usdc, accounts, spotIds);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyHoldRunsAsLongAsItsBudgetPays() public view {
        for (uint256 s; s < spotIds.length; ++s) {
            (OfferExchange.Hold[3] memory holds,) = exchange.spotHolds(spotIds[s]);
            for (uint256 i; i < 3; ++i) {
                OfferExchange.Hold memory hold = holds[i];
                if (hold.bidder == address(0)) {
                    assertEq(hold.budget, 0);
                    assertEq(hold.endsAt, 0);
                } else {
                    assertEq(hold.endsAt - hold.start, hold.budget / hold.rate);
                    assertGe(hold.endsAt - hold.start, 60);
                }
            }
        }
    }

    /// @dev Proves each run reached every way money moves, not only refused calls. Measured over
    ///      3,072 runs on three seeds, every path was reached at least three times in every run.
    function afterInvariant() external view {
        string[8] memory paths =
            ["empty slot", "overtake", "reuse run-out slot", "leave", "remove", "settle", "withdraw", "push"];
        for (uint256 i; i < paths.length; ++i) {
            assertGt(handler.reached(paths[i]), 0, paths[i]);
        }
    }
}
