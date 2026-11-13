// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRegentRevenueStaking} from "./PatchbayEscrow.sol";

/// @title OfferExchange
/// @notice A market where bidders pay USDC to have an Offer shown to agents in a spot on a listed
///         site. Every spot has three slots. A bidder buys time: it names a rate in USDC per second
///         and a budget, and holds a slot from the moment it bids until the budget runs out, it
///         leaves, the site removes it, or a bid at least 5% higher takes the slot. Each holder pays
///         its own rate for the seconds it held. Of what a hold is charged, 90% goes to the site's
///         payout wallet and 10% to REGENT revenue staking; the unspent budget goes back to the
///         bidder.
/// @dev Nothing is paid out while bidding. A settlement only credits `owed`, and every address
///      takes its own credit with `withdraw`, so a frozen wallet can never block anyone else's bid,
///      leave, removal, settlement or withdrawal. The revenue share is kept in `revenueOwed` and
///      anyone may push it to the staking contract, as the escrow does. The owner lists sites and
///      may pause new bids; it cannot move money, change the split, or stop leaving, removal,
///      settlement or withdrawal. There is no upgrade. Time is counted in seconds of
///      `block.timestamp`, never in blocks, so a change in Base's block time changes no price.
contract OfferExchange is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Why a hold ended, other than being overtaken (which has its own event).
    enum EndReason {
        Left,
        Removed,
        RanOut
    }

    /// @notice A place on a site where up to three Offers show.
    /// @param siteId The site the spot belongs to.
    /// @param minRate The lowest rate a bid may name, in USDC base units per second. Never zero, so
    ///        a zero `minRate` marks a spot id that was never added.
    struct Spot {
        uint256 siteId;
        uint96 minRate;
    }

    /// @notice One bidder's paid time in one slot.
    /// @param bidder The address that bid and is refunded what the hold does not spend.
    /// @param start The moment the hold began.
    /// @param offerId The fingerprint of the Offer shown while the hold is live.
    /// @param rate What the hold pays, in USDC base units per second.
    /// @param budget The USDC paid in for this hold, held by the exchange until it is settled.
    /// @param endsAt The moment the budget runs out: `start + budget / rate`. The hold is live while
    ///        `block.timestamp < endsAt`. A slot never held, or already settled, has `endsAt` zero.
    struct Hold {
        address bidder;
        uint64 start;
        bytes32 offerId;
        uint96 rate;
        uint96 budget;
        uint64 endsAt;
    }

    /// @notice Number of slots in every spot.
    uint256 public constant SLOTS = 3;

    /// @notice Shortest hold a bid must fund, and the least a bidder who leaves is charged for, in
    ///         seconds. It makes taking a slot and leaving at once cost something.
    uint256 public constant MIN_HOLD = 60;

    /// @notice How much a bid must beat the lowest live rate by to take its slot, in basis points.
    uint256 public constant MIN_STEP_BPS = 500;

    /// @notice Share of every charge kept as revenue for REGENT stakers, in basis points. The site
    ///         is credited the rest, so rounding never shorts the site by more than one base unit.
    uint256 public constant REVENUE_BPS = 1000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The source tag every push carries, so stakers can see the revenue came from here.
    // casting to 'bytes32' is safe because the 15-character literal fits in 32 bytes
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_TAG = bytes32("offers.exchange");

    /// @notice The USDC token bids are paid in.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The REGENT revenue staking contract the revenue share is pushed into.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice While true, `bid` reverts. Nothing else is ever paused.
    bool public paused;

    /// @notice Number of sites listed; site ids run from 1 to this.
    uint256 public siteCount;

    /// @notice Number of spots added; spot ids run from 1 to this.
    uint256 public spotCount;

    /// @notice Revenue share of every settlement not yet pushed to the staking contract.
    uint256 public revenueOwed;

    /// @notice Each site's payout wallet, which manages the site and is credited its 90%.
    mapping(uint256 siteId => address payout) public sitePayout;

    /// @notice Every spot, keyed by spot id.
    mapping(uint256 spotId => Spot) public spots;

    /// @notice USDC each address may take with `withdraw`: site earnings and unspent budgets.
    mapping(address account => uint256 amount) public owed;

    /// @dev The three slots of every spot. Read them with `spotHolds`.
    mapping(uint256 spotId => Hold[SLOTS]) private _holds;

    /// @notice Emitted when the owner lists a site.
    event SiteListed(uint256 indexed siteId, address indexed payout);

    /// @notice Emitted when a site's payout wallet hands the site to a new payout wallet.
    event PayoutChanged(uint256 indexed siteId, address indexed previousPayout, address indexed newPayout);

    /// @notice Emitted when a site adds a spot.
    event SpotAdded(uint256 indexed spotId, uint256 indexed siteId, uint96 minRate);

    /// @notice Emitted when a bid takes a slot.
    event BidPlaced(
        uint256 indexed spotId,
        address indexed bidder,
        bytes32 indexed offerId,
        uint256 slot,
        uint96 rate,
        uint96 budget,
        uint64 endsAt
    );

    /// @notice Emitted when a live hold is settled because a higher bid took its slot.
    /// @param bidder The holder that lost the slot.
    /// @param by The bidder that took it.
    /// @param rate The rate the new bid pays.
    /// @param charged What the overtaken hold was charged for the time it held.
    /// @param refund The unspent budget credited back to the overtaken holder.
    event Overtaken(
        uint256 indexed spotId,
        address indexed bidder,
        address indexed by,
        uint256 slot,
        uint96 rate,
        uint256 charged,
        uint256 refund
    );

    /// @notice Emitted when a hold is settled because its holder left, its site removed it, or its
    ///         budget ran out.
    event HoldEnded(
        uint256 indexed spotId, address indexed bidder, uint256 slot, EndReason reason, uint256 charged, uint256 refund
    );

    /// @notice Emitted when an address takes the USDC it is owed.
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice Emitted when the revenue owed is deposited into the staking contract.
    event RevenuePushed(address indexed caller, uint256 amount);

    /// @notice Emitted when the owner pauses or resumes new bids.
    event PauseSet(bool paused);

    /// @notice Thrown when a constructor address is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a payout wallet is the zero address or the exchange itself.
    error InvalidPayout();

    /// @notice Thrown when a call only a site's payout wallet may make comes from another address.
    error NotSite();

    /// @notice Thrown when a spot is added with a zero minimum rate.
    error ZeroRate();

    /// @notice Thrown when a bid names a spot id that was never added.
    error UnknownSpot();

    /// @notice Thrown when a slot index is not below `SLOTS`.
    error UnknownSlot();

    /// @notice Thrown when a bid's Offer fingerprint is zero.
    error ZeroOffer();

    /// @notice Thrown when a bid's rate is below the spot's minimum rate.
    error RateTooLow();

    /// @notice Thrown when a bid's budget does not fund `MIN_HOLD` seconds at its rate.
    error BudgetTooSmall();

    /// @notice Thrown when a bid arrives while new bids are paused.
    error BidsPaused();

    /// @notice Thrown when every slot is live and the bid does not beat the lowest by `MIN_STEP_BPS`.
    error BidTooLow();

    /// @notice Thrown when a holder-only call comes from another address.
    error NotHolder();

    /// @notice Thrown when a leave or removal names a slot with no live hold.
    error NotLive();

    /// @notice Thrown when a settlement names a slot that is empty or whose hold is still live.
    error NothingToSettle();

    /// @notice Thrown when a withdrawal or push finds nothing owed.
    error NothingOwed();

    /// @notice Deploys the exchange. `owner_` is the owner from construction; Ownable2Step applies
    ///         to later handovers.
    /// @param usdc_ The USDC token address on this chain.
    /// @param staking_ The REGENT revenue staking contract the 10% revenue share is pushed into.
    /// @param owner_ The address that may list sites, pause new bids and transfer ownership.
    constructor(IERC20 usdc_, IRegentRevenueStaking staking_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        if (address(staking_) == address(0)) revert ZeroAddress();

        usdc = usdc_;
        staking = staking_;
    }

    /// @notice Lists a site whose spots bidders may then bid on.
    /// @dev Owner only. The payout wallet manages the site from then on; the owner cannot change it.
    /// @param payout The site's payout wallet.
    /// @return siteId The new site's id.
    function listSite(address payout) external onlyOwner returns (uint256 siteId) {
        _checkPayout(payout);

        siteId = ++siteCount;
        // `SiteListed` below records the new payout wallet.
        // forge-lint: disable-next-line(missing-events-access-control)
        sitePayout[siteId] = payout;

        emit SiteListed(siteId, payout);
    }

    /// @notice Pauses or resumes new bids.
    /// @dev Owner only. Leaving, removal, settlement, withdrawal and the revenue push never pause.
    /// @param paused_ True to refuse new bids, false to accept them again.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;

        emit PauseSet(paused_);
    }

    /// @notice Hands a site to a new payout wallet.
    /// @dev Site only. Credit already earned stays with the old wallet; settlements from now on
    ///      credit the new one.
    /// @param siteId The site to hand over.
    /// @param newPayout The new payout wallet.
    function setPayout(uint256 siteId, address newPayout) external {
        _checkSite(siteId);
        _checkPayout(newPayout);

        emit PayoutChanged(siteId, msg.sender, newPayout);
        // forge-lint: disable-next-line(missing-events-access-control)
        sitePayout[siteId] = newPayout;
    }

    /// @notice Adds a spot with three slots to a site.
    /// @dev Site only.
    /// @param siteId The site the spot belongs to.
    /// @param minRate The lowest rate a bid may name, in USDC base units per second; above zero.
    /// @return spotId The new spot's id.
    function addSpot(uint256 siteId, uint96 minRate) external returns (uint256 spotId) {
        _checkSite(siteId);
        if (minRate == 0) revert ZeroRate();

        spotId = ++spotCount;
        spots[spotId] = Spot({siteId: siteId, minRate: minRate});

        emit SpotAdded(spotId, siteId, minRate);
    }

    /// @notice Pays `budget` USDC in to show `offerId` in a slot of `spotId` at `rate` per second,
    ///         from now until the budget runs out.
    /// @dev Takes the first slot that is free (never held, or its hold has ended). With all three
    ///      live, it takes the slot of the lowest rate, which it must beat by at least
    ///      `MIN_STEP_BPS`; among equal lowest rates the latest hold is the one taken, so the
    ///      earlier holder keeps its slot. The hold it replaces is settled to this moment first. The
    ///      bidder must have approved `budget`.
    ///
    ///      The budget is pulled before the slot is chosen and written, the order OpenZeppelin's
    ///      ERC4626 deposit uses: should the token ever call back into the exchange mid-transfer,
    ///      the call would only see a finished state with every credit fully backed.
    /// @param spotId The spot to bid on.
    /// @param offerId The fingerprint of the Offer to show; not zero.
    /// @param rate USDC base units per second; at least the spot's minimum rate.
    /// @param budget USDC base units paid in; enough for at least `MIN_HOLD` seconds at `rate`.
    /// @return slot The slot taken.
    function bid(uint256 spotId, bytes32 offerId, uint96 rate, uint96 budget) external returns (uint256 slot) {
        if (paused) revert BidsPaused();
        uint96 minRate = spots[spotId].minRate;
        if (minRate == 0) revert UnknownSpot();
        if (offerId == bytes32(0)) revert ZeroOffer();
        if (rate < minRate) revert RateTooLow();
        if (budget < uint256(rate) * MIN_HOLD) revert BudgetTooSmall();

        usdc.safeTransferFrom(msg.sender, address(this), budget);

        Hold[SLOTS] storage holds = _holds[spotId];
        slot = _slotFor(holds);
        Hold storage taken = holds[slot];
        if (_isLive(taken.endsAt)) {
            if (uint256(rate) * BPS < uint256(taken.rate) * (BPS + MIN_STEP_BPS)) revert BidTooLow();
            (address holder, uint256 charged, uint256 refund) = _settle(spotId, slot, block.timestamp - taken.start);
            emit Overtaken(spotId, holder, msg.sender, slot, rate, charged, refund);
        } else if (taken.bidder != address(0)) {
            _end(spotId, slot, taken.endsAt - taken.start, EndReason.RanOut);
        }

        uint64 endsAt = SafeCast.toUint64(block.timestamp + budget / rate);
        holds[slot] = Hold({
            bidder: msg.sender,
            start: SafeCast.toUint64(block.timestamp),
            offerId: offerId,
            rate: rate,
            budget: budget,
            endsAt: endsAt
        });

        emit BidPlaced(spotId, msg.sender, offerId, slot, rate, budget, endsAt);
    }

    /// @notice Ends the caller's own live hold early.
    /// @dev Holder only. Charged for the seconds held, but never fewer than `MIN_HOLD`.
    /// @param spotId The spot the hold is in.
    /// @param slot The slot the hold is in.
    function leave(uint256 spotId, uint256 slot) external {
        Hold storage hold = _hold(spotId, slot);
        if (hold.bidder != msg.sender) revert NotHolder();
        if (!_isLive(hold.endsAt)) revert NotLive();

        uint256 held = block.timestamp - hold.start;
        // forge-lint: disable-next-line(block-timestamp)
        _end(spotId, slot, held < MIN_HOLD ? MIN_HOLD : held, EndReason.Left);
    }

    /// @notice Takes down a live hold whose Offer the site does not want shown.
    /// @dev Site only. Charged for the seconds actually held, with no minimum.
    /// @param spotId The spot the hold is in.
    /// @param slot The slot the hold is in.
    function remove(uint256 spotId, uint256 slot) external {
        _checkSite(spots[spotId].siteId);
        Hold storage hold = _hold(spotId, slot);
        if (!_isLive(hold.endsAt)) revert NotLive();

        _end(spotId, slot, block.timestamp - hold.start, EndReason.Removed);
    }

    /// @notice Settles a hold whose budget has run out, crediting the site, the revenue owed and
    ///         the bidder's unspent remainder.
    /// @dev Anyone may call this; the money can only be credited where the hold says. A bid that
    ///      takes the slot settles it too.
    /// @param spotId The spot the hold is in.
    /// @param slot The slot the hold is in.
    function settle(uint256 spotId, uint256 slot) external {
        Hold storage hold = _hold(spotId, slot);
        if (hold.bidder == address(0) || _isLive(hold.endsAt)) revert NothingToSettle();

        _end(spotId, slot, hold.endsAt - hold.start, EndReason.RanOut);
    }

    /// @notice Sends the caller all the USDC it is owed.
    /// @return amount The USDC sent, in 6-decimal base units.
    function withdraw() external returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;

        emit Withdrawn(msg.sender, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Deposits all the revenue owed into the REGENT revenue staking contract, tagged
    ///         `offers.exchange`.
    /// @dev Anyone may call this: the money can only go to the immutable staking contract. While
    ///      that contract is paused the deposit reverts and the revenue stays owed.
    /// @return amount The USDC pushed, in 6-decimal base units.
    function pushRevenue() external returns (uint256 amount) {
        amount = revenueOwed;
        if (amount == 0) revert NothingOwed();
        revenueOwed = 0;

        emit RevenuePushed(msg.sender, amount);

        usdc.forceApprove(address(staking), amount);
        // The staking contract records what it received itself; USDC moves the exact amount.
        // slither-disable-next-line unused-return
        staking.depositUSDC(amount, SOURCE_TAG, bytes32(0)); // forge-lint: disable-line(unused-return)
    }

    /// @notice A spot's three holds and which of them are live now.
    /// @dev A hold that is not live but still has a bidder has run out and not been settled yet;
    ///      the next bid on its slot, or anyone's `settle`, settles it.
    /// @param spotId The spot to read.
    /// @return holds The hold in each slot; an empty slot is all zeros.
    /// @return live Whether each slot's Offer should show now.
    function spotHolds(uint256 spotId) external view returns (Hold[SLOTS] memory holds, bool[SLOTS] memory live) {
        holds = _holds[spotId];
        for (uint256 i; i < SLOTS; ++i) {
            live[i] = _isLive(holds[i].endsAt);
        }
    }

    /// @dev Settles a hold and emits `HoldEnded`.
    function _end(uint256 spotId, uint256 slot, uint256 held, EndReason reason) private {
        (address bidder, uint256 charged, uint256 refund) = _settle(spotId, slot, held);
        emit HoldEnded(spotId, bidder, slot, reason, charged, refund);
    }

    /// @dev Charges a hold for `held` seconds and clears its slot. Of the charge, `REVENUE_BPS`
    ///      rounded down is revenue owed and the rest is credited to the site's payout wallet as it
    ///      is now; the budget left over is credited to the bidder. The three parts always sum to
    ///      the budget exactly. Every caller passes `held` no larger than `endsAt - start`, which is
    ///      `budget / rate` rounded down, so the charge never exceeds the budget.
    function _settle(uint256 spotId, uint256 slot, uint256 held)
        private
        returns (address bidder, uint256 charged, uint256 refund)
    {
        Hold storage hold = _holds[spotId][slot];
        bidder = hold.bidder;
        charged = uint256(hold.rate) * held;
        refund = hold.budget - charged;
        uint256 revenue = (charged * REVENUE_BPS) / BPS;
        delete _holds[spotId][slot];

        owed[sitePayout[spots[spotId].siteId]] += charged - revenue;
        revenueOwed += revenue;
        owed[bidder] += refund;
    }

    /// @dev The first slot whose hold is not live; with all three live, the lowest rate, and among
    ///      equal rates the latest start (the higher slot when starts are equal).
    function _slotFor(Hold[SLOTS] storage holds) private view returns (uint256 slot) {
        for (uint256 i; i < SLOTS; ++i) {
            Hold storage hold = holds[i];
            if (!_isLive(hold.endsAt)) return i;
            Hold storage lowest = holds[slot];
            if (hold.rate < lowest.rate || (hold.rate == lowest.rate && hold.start >= lowest.start)) slot = i;
        }
    }

    /// @dev A slot's hold, after checking the slot index.
    function _hold(uint256 spotId, uint256 slot) private view returns (Hold storage) {
        if (slot >= SLOTS) revert UnknownSlot();
        return _holds[spotId][slot];
    }

    /// @dev Whether a hold ending at `endsAt` is live now. Seconds, not blocks, are the unit of
    ///      every hold, so the comparison with the block's time is the design.
    function _isLive(uint64 endsAt) private view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < endsAt;
    }

    /// @dev Reverts unless the caller is the site's payout wallet. An unknown site has none.
    function _checkSite(uint256 siteId) private view {
        if (msg.sender != sitePayout[siteId]) revert NotSite();
    }

    /// @dev Rejects a payout wallet whose credit could never be withdrawn.
    function _checkPayout(address payout) private view {
        if (payout == address(0) || payout == address(this)) revert InvalidPayout();
    }
}
