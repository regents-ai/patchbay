// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice The EIP-3009 function of USDC (FiatTokenV2_2) a bid is funded through.
/// @dev USDC accepts a `ReceiveWithAuthorization` only from its `to`, so only this contract can
///      use a bidder's signature. The `bytes` form checks contract wallets through ERC-1271.
interface IUSDCReceiveWithAuthorization {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/// @notice The one function of the REGENT revenue staking contract the protocol share is paid into.
interface IRegentRevenueStaking {
    /// @notice Pulls `amount` USDC from the caller and credits it to REGENT stakers as revenue.
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}

/// @title RegentOffers
/// @notice A USDC market for Agent Offer slots on Regent sites (venues). Every forum a venue runs
///         has its slots (inventory) with no listing step, and bidders commit USDC to them (demand).
///         Patchbay.help is the first venue.
/// @dev The venue's server (its operator) screens wordings, keeps the slot order and chooses
///      winners; a separate moderator, set by the owner, removes placements for policy; this
///      contract keeps the money under fixed rules. Because a removal pays the whole bid, the
///      operator can never remove, so a stolen operator key can charge at most one placement per
///      slot at a time, for the time it shows. A bid is a USDC authorization
///      signed by the bidder, bound to the bid's exact terms through its nonce and submitted by
///      anyone, so a bidder needs no ETH. Bid money leaves only as a return of a bid never placed
///      (or the unused time of a placement replaced by a newer one), or as payment for its
///      placement, split between REGENT staking and the venue's payout wallet. Nothing is paid out
///      inline: every end records what is owed and `payOut` sends it, so an address USDC refuses
///      to pay can never stop a slot from ending or being replaced. There is no upgrade: a new
///      market is a new contract, and pausing this one stops new bids only.
contract RegentOffers is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Where a bid stands. `None` is the zero value, so an unknown id is never mistaken for a bid.
    enum Status {
        None,
        Held,
        Placed,
        Ended,
        Returned,
        Withdrawn
    }

    /// @notice Why a placement ended.
    enum EndReason {
        Finished,
        Replaced,
        Removed
    }

    /// @notice What a bidder signs for. Its hash is the USDC authorization's nonce.
    /// @param venue The venue's id, such as `keccak256("patchbay.help")`.
    /// @param slot The slot's id within the venue, chosen by the venue (for Patchbay, a forum's
    ///        market and slot number).
    /// @param lane The venue's own lane for the bid; recorded, never read by the contract.
    /// @param wordingHash The exact Offer wording the venue screened.
    /// @param amount USDC base units committed.
    /// @param length The venue's placement length in seconds, which must match its current terms.
    /// @param placeBy After this time the bid can no longer be placed and anyone may withdraw it.
    /// @param salt The bidder's own value, so two equal bids have different nonces.
    struct Terms {
        bytes32 venue;
        bytes32 slot;
        uint8 lane;
        bytes32 wordingHash;
        uint96 amount;
        uint32 length;
        uint64 placeBy;
        bytes32 salt;
    }

    /// @notice A venue whose forums carry slots. A zero admin means the venue was never added.
    /// @param operator The venue's server key: places and returns bids.
    /// @param moderator Removes placements for policy; never the operator.
    /// @param minimum The least bid, in USDC base units, on any of its slots.
    /// @param length How long a placement runs, in seconds.
    struct Venue {
        address admin;
        address operator;
        address moderator;
        address payout;
        uint96 minimum;
        uint32 length;
    }

    /// @notice A bid, held until it is placed, returned or withdrawn.
    struct Bid {
        address bidder;
        uint96 amount;
        bytes32 venue;
        bytes32 slot;
        uint64 placeBy;
        uint64 startsAt;
        uint32 length;
        Status status;
    }

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Tag the protocol share is deposited into REGENT staking under.
    // casting to bytes32 is safe because the 13-byte literal fits
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_TAG = bytes32("regent.offers");

    /// @notice The USDC token bids are paid in.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The REGENT revenue staking contract the protocol share is pushed into.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice Share of a placement's payment sent to REGENT staking, in basis points. The rest
    ///         goes to the venue's payout wallet.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable protocolBps;

    /// @notice While true, new bids are refused. Nothing else ever pauses.
    bool public paused;

    mapping(bytes32 venue => Venue) public venues;

    /// @notice The one showing placement of each slot, or zero.
    mapping(bytes32 venue => mapping(bytes32 slot => bytes32 bidId)) public live;

    mapping(bytes32 bidId => Bid) public bids;

    /// @notice USDC each account may be sent with `payOut`.
    mapping(address account => uint256) public owed;

    /// @notice USDC in bids that are held or placed.
    uint256 public totalCommitted;

    /// @notice Sum of `owed` over every account.
    uint256 public totalOwed;

    /// @notice The protocol share waiting for `pushRevenue`.
    uint256 public revenueOwed;

    event VenueAdded(
        bytes32 indexed venue,
        address admin,
        address operator,
        address moderator,
        address payout,
        uint96 minimum,
        uint32 length
    );
    event VenueAdminChanged(bytes32 indexed venue, address admin);
    event OperatorChanged(bytes32 indexed venue, address operator);
    event ModeratorChanged(bytes32 indexed venue, address moderator);
    event PayoutChanged(bytes32 indexed venue, address payout);
    event VenueTermsChanged(bytes32 indexed venue, uint96 minimum, uint32 length);
    event BidPlaced(
        bytes32 indexed bidId,
        bytes32 indexed venue,
        bytes32 indexed slot,
        address bidder,
        uint8 lane,
        bytes32 wordingHash,
        uint96 amount,
        uint32 length,
        uint64 placeBy,
        bytes32 nonce
    );
    event BidReturned(bytes32 indexed bidId, address indexed bidder, uint256 amount);
    event BidWithdrawn(bytes32 indexed bidId, address indexed bidder, uint256 amount);
    event Placed(bytes32 indexed bidId, bytes32 indexed venue, bytes32 indexed slot, uint64 startsAt, uint64 endsAt);
    event Ended(
        bytes32 indexed bidId,
        EndReason reason,
        uint256 paid,
        uint256 returned,
        uint256 protocolShare,
        uint256 venueShare,
        address payout
    );
    event PaidOut(address indexed account, address indexed caller, uint256 amount);
    event RevenuePushed(address indexed caller, uint256 amount);
    event PausedSet(bool paused);

    error ZeroAddress();
    error ZeroValue();
    error ShareTooLarge();
    error ContractIsParty();
    error VenueExists();
    error VenueNotFound();
    error NotVenueAdmin();
    error NotOperator();
    error NotModerator();
    error ModeratorIsOperator();
    error BidsPaused();
    error BelowMinimum();
    error LengthMismatch();
    error PlaceByPassed();
    error PlaceByNotPassed();
    error BidExists();
    error AmountNotReceived();
    error NotHeld();
    error NotPlaced();
    error NotFinished();
    error NothingOwed();
    error OwnerRequired();

    constructor(IERC20 usdc_, IRegentRevenueStaking staking_, uint256 protocolBps_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0) || address(staking_) == address(0)) revert ZeroAddress();
        if (protocolBps_ > BPS) revert ShareTooLarge();
        usdc = usdc_;
        staking = staking_;
        protocolBps = protocolBps_;
    }

    // ---------------------------------------------------------------- owner

    /// @notice Adds a venue. Every forum it runs carries slots from then on.
    function addVenue(
        bytes32 venue,
        address admin,
        address operator,
        address moderator,
        address payout,
        uint96 minimum,
        uint32 length
    ) external onlyOwner {
        if (venue == bytes32(0) || minimum == 0 || length == 0) revert ZeroValue();
        if (venues[venue].admin != address(0)) revert VenueExists();
        if (admin == address(0) || operator == address(0) || moderator == address(0)) revert ZeroAddress();
        if (moderator == operator) revert ModeratorIsOperator();
        _checkPayout(payout);
        venues[venue] = Venue({
            admin: admin, operator: operator, moderator: moderator, payout: payout, minimum: minimum, length: length
        });
        emit VenueAdded(venue, admin, operator, moderator, payout, minimum, length);
    }

    /// @notice Replaces a venue's moderator. Only the owner may, because a removal pays the whole bid.
    function setModerator(bytes32 venue, address moderator) external onlyOwner {
        Venue storage v = _venue(venue);
        if (moderator == address(0)) revert ZeroAddress();
        if (moderator == v.operator) revert ModeratorIsOperator();
        v.moderator = moderator;
        emit ModeratorChanged(venue, moderator);
    }

    /// @notice Replaces a venue's admin, for when its key is lost or leaked.
    function setVenueAdmin(bytes32 venue, address admin) external onlyOwner {
        _venue(venue);
        if (admin == address(0)) revert ZeroAddress();
        venues[venue].admin = admin;
        emit VenueAdminChanged(venue, admin);
    }

    /// @notice Stops or restarts new bids. Placing, returns, withdrawals, finishing and payouts
    ///         never pause, so money already in can always leave.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Ownership can be handed on but never given up, so a pause always has someone to lift it.
    function renounceOwnership() public view override onlyOwner {
        revert OwnerRequired();
    }

    // ---------------------------------------------------------- venue admin

    function setOperator(bytes32 venue, address operator) external {
        _onlyVenueAdmin(venue);
        if (operator == address(0)) revert ZeroAddress();
        if (operator == venues[venue].moderator) revert ModeratorIsOperator();
        venues[venue].operator = operator;
        emit OperatorChanged(venue, operator);
    }

    function setPayout(bytes32 venue, address payout) external {
        _onlyVenueAdmin(venue);
        _checkPayout(payout);
        venues[venue].payout = payout;
        emit PayoutChanged(venue, payout);
    }

    /// @notice Changes the least bid and the placement length for bids from now on. A bid already
    ///         held or showing keeps the length it was made under.
    function setTerms(bytes32 venue, uint96 minimum, uint32 length) external {
        _onlyVenueAdmin(venue);
        if (minimum == 0 || length == 0) revert ZeroValue();
        venues[venue].minimum = minimum;
        venues[venue].length = length;
        emit VenueTermsChanged(venue, minimum, length);
    }

    // ----------------------------------------------------------------- bids

    /// @notice The USDC authorization nonce a bidder signs for `terms`.
    function nonceOf(Terms calldata terms) public pure returns (bytes32) {
        return keccak256(abi.encode(terms));
    }

    /// @notice The id a bid by `bidder` on `terms` is held under.
    function bidIdOf(address bidder, Terms calldata terms) public pure returns (bytes32) {
        return keccak256(abi.encode(bidder, nonceOf(terms)));
    }

    /// @notice Holds a bid, funded by the bidder's signed USDC `ReceiveWithAuthorization` to this
    ///         contract for `terms.amount`, whose nonce is `nonceOf(terms)`. Anyone may submit it.
    // Balances are read on either side of the USDC call on purpose, to check the exact amount moved.
    // USDC asks a contract wallet about its signature with a read-only call, and every function that
    // changes state holds the same guard, so nothing re-enters.
    // slither-disable-next-line reentrancy-balance,timestamp
    function bid(
        Terms calldata terms,
        address bidder,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 bidId) {
        if (paused) revert BidsPaused();
        if (bidder == address(0)) revert ZeroAddress();
        if (bidder == address(this)) revert ContractIsParty();
        if (terms.slot == bytes32(0)) revert ZeroValue();
        Venue storage v = _venue(terms.venue);
        if (terms.amount < v.minimum) revert BelowMinimum();
        if (terms.length != v.length) revert LengthMismatch();
        // Times here are hours apart; a block producer's few seconds of leeway changes nothing.
        // forge-lint: disable-next-line(block-timestamp)
        if (terms.placeBy <= block.timestamp) revert PlaceByPassed();

        bytes32 nonce = nonceOf(terms);
        bidId = keccak256(abi.encode(bidder, nonce));
        if (bids[bidId].status != Status.None) revert BidExists();

        bids[bidId] = Bid({
            bidder: bidder,
            amount: terms.amount,
            venue: terms.venue,
            slot: terms.slot,
            placeBy: terms.placeBy,
            startsAt: 0,
            length: terms.length,
            status: Status.Held
        });
        totalCommitted += terms.amount;

        _emitBidPlaced(bidId, terms, bidder, nonce);

        uint256 before = usdc.balanceOf(address(this));
        IUSDCReceiveWithAuthorization(address(usdc))
            .receiveWithAuthorization(bidder, address(this), terms.amount, validAfter, validBefore, nonce, signature);
        // USDC moves the exact amount; anything else means the token changed and the bid must fail.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (usdc.balanceOf(address(this)) - before != terms.amount) revert AmountNotReceived();
    }

    /// @notice Shows a held bid in its slot from this block's time. A placement already showing in
    ///         the slot ends as replaced in the same call, its unused time owed back to its bidder.
    // slither-disable-next-line timestamp
    function place(bytes32 bidId) external nonReentrant {
        Bid storage b = bids[bidId];
        if (b.status != Status.Held) revert NotHeld();
        _onlyOperator(b.venue);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= b.placeBy) revert PlaceByPassed();

        bytes32 current = live[b.venue][b.slot];
        if (current != bytes32(0)) _end(current, EndReason.Replaced);

        // casting to uint64 is safe because block times stay below 2^64 seconds
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 startsAt = uint64(block.timestamp);
        b.status = Status.Placed;
        b.startsAt = startsAt;
        live[b.venue][b.slot] = bidId;
        emit Placed(bidId, b.venue, b.slot, startsAt, startsAt + b.length);
    }

    /// @notice Gives a held bid back to its bidder in full.
    function returnBid(bytes32 bidId) external nonReentrant {
        Bid storage b = bids[bidId];
        if (b.status != Status.Held) revert NotHeld();
        _onlyOperator(b.venue);
        b.status = Status.Returned;
        _giveBack(b);
        emit BidReturned(bidId, b.bidder, b.amount);
    }

    /// @notice Gives back a bid that was never placed, once its `placeBy` has passed. Anyone may call it.
    // slither-disable-next-line timestamp
    function withdraw(bytes32 bidId) external nonReentrant {
        Bid storage b = bids[bidId];
        if (b.status != Status.Held) revert NotHeld();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < b.placeBy) revert PlaceByNotPassed();
        b.status = Status.Withdrawn;
        _giveBack(b);
        emit BidWithdrawn(bidId, b.bidder, b.amount);
    }

    /// @notice Ends a showing placement for policy. The whole bid is paid; nothing goes back.
    ///         Only the venue's moderator may.
    function remove(bytes32 bidId) external nonReentrant {
        Bid storage b = bids[bidId];
        if (b.status != Status.Placed) revert NotPlaced();
        if (msg.sender != venues[b.venue].moderator) revert NotModerator();
        _end(bidId, EndReason.Removed);
    }

    /// @notice Ends a placement whose time is up, all of it paid. Anyone may call it.
    // slither-disable-next-line timestamp
    function finish(bytes32 bidId) external nonReentrant {
        Bid storage b = bids[bidId];
        if (b.status != Status.Placed) revert NotPlaced();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(b.startsAt) + b.length) revert NotFinished();
        _end(bidId, EndReason.Finished);
    }

    // ------------------------------------------------------------- payouts

    /// @notice Sends `account` everything it is owed. Anyone may call it; only `account` is paid.
    function payOut(address account) external nonReentrant returns (uint256 amount) {
        amount = owed[account];
        if (amount == 0) revert NothingOwed();
        owed[account] = 0;
        totalOwed -= amount;
        emit PaidOut(account, msg.sender, amount);
        usdc.safeTransfer(account, amount);
    }

    /// @notice Deposits the protocol share owed into REGENT staking. Anyone may call it.
    // slither-disable-next-line reentrancy-balance
    function pushRevenue() external nonReentrant returns (uint256 amount) {
        amount = revenueOwed;
        if (amount == 0) revert NothingOwed();
        revenueOwed = 0;
        emit RevenuePushed(msg.sender, amount);
        uint256 before = usdc.balanceOf(address(this));
        usdc.forceApprove(address(staking), amount);
        // The staking contract records what it received itself; this contract checks its own
        // balance instead, so the books stay exact whatever the staking contract answers.
        // forge-lint: disable-start(unused-return)
        // slither-disable-next-line unused-return
        staking.depositUSDC(amount, SOURCE_TAG, bytes32(0));
        // forge-lint: disable-end(unused-return)
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (before - usdc.balanceOf(address(this)) != amount) revert AmountNotReceived();
    }

    /// @notice How a placement's amount divides if it ends at `at` for `reason`: what is paid, what
    ///         goes back to the bidder, and the protocol's and venue's shares of what is paid. A
    ///         replaced placement pays for the time it showed; a finished or removed one pays all.
    // slither-disable-next-line timestamp
    function split(uint256 amount, uint256 startsAt, uint256 length, uint256 at, EndReason reason)
        public
        view
        returns (uint256 paid, uint256 returned, uint256 protocolShare, uint256 venueShare)
    {
        if (reason == EndReason.Replaced) {
            uint256 shown = at - startsAt;
            if (shown > length) shown = length;
            paid = (amount * shown) / length;
        } else {
            paid = amount;
        }
        returned = amount - paid;
        // The protocol's share is of what was paid, so it follows the time division on purpose.
        // forge-lint: disable-next-line(divide-before-multiply)
        protocolShare = (paid * protocolBps) / BPS;
        venueShare = paid - protocolShare;
    }

    // ------------------------------------------------------------ internal

    function _end(bytes32 bidId, EndReason reason) private {
        Bid storage b = bids[bidId];
        (uint256 paid, uint256 returned, uint256 protocolShare, uint256 venueShare) =
            split(b.amount, b.startsAt, b.length, block.timestamp, reason);
        address payout = venues[b.venue].payout;

        b.status = Status.Ended;
        live[b.venue][b.slot] = bytes32(0);
        totalCommitted -= b.amount;
        owed[b.bidder] += returned;
        owed[payout] += venueShare;
        totalOwed += returned + venueShare;
        revenueOwed += protocolShare;

        emit Ended(bidId, reason, paid, returned, protocolShare, venueShare, payout);
    }

    function _emitBidPlaced(bytes32 bidId, Terms calldata terms, address bidder, bytes32 nonce) private {
        emit BidPlaced(
            bidId,
            terms.venue,
            terms.slot,
            bidder,
            terms.lane,
            terms.wordingHash,
            terms.amount,
            terms.length,
            terms.placeBy,
            nonce
        );
    }

    function _giveBack(Bid storage b) private {
        totalCommitted -= b.amount;
        owed[b.bidder] += b.amount;
        totalOwed += b.amount;
    }

    function _venue(bytes32 venue) private view returns (Venue storage v) {
        v = venues[venue];
        if (v.admin == address(0)) revert VenueNotFound();
    }

    function _onlyVenueAdmin(bytes32 venue) private view {
        if (msg.sender != _venue(venue).admin) revert NotVenueAdmin();
    }

    function _onlyOperator(bytes32 venue) private view {
        if (msg.sender != venues[venue].operator) revert NotOperator();
    }

    function _checkPayout(address payout) private view {
        if (payout == address(0)) revert ZeroAddress();
        if (payout == address(this)) revert ContractIsParty();
    }
}
