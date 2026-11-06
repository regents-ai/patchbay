// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice The EIP-3009 function of USDC (FiatTokenV2_2) a bid is funded through.
/// @dev USDC accepts a `ReceiveWithAuthorization` only from its `to`, so only this contract can
///      use a bidder's signature. The `bytes` form checks an account with code, such as a contract
///      wallet or an EIP-7702 account, through ERC-1271.
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
///      winners; a separate moderator removes placements for policy; this contract keeps the
///      money under fixed rules. Because a removal pays the whole bid, the moderator is never the
///      venue's admin or its operator, so the key that places, and the key that names who
///      places, can never remove: a stolen operator or admin key can charge at most one
///      placement per slot at a time, for the time it shows, paid to the venue. Regents Labs
///      holds the moderator key in a hardware wallet or a Safe. Only that separation is
///      enforced: an admin can block the owner's choice of moderator by naming that address
///      operator first, and the owner then picks another key.
///
///      A venue's admin sets its terms for new bids. A stolen admin key can stop every new bid
///      with a minimum nobody meets, or set a one-second length, so a bid signed at that length
///      is charged in full a second after it is placed. A signature made at the old length
///      names it, and is refused at the new one.
///
///      A bid is one USDC `ReceiveWithAuthorization` signed by the bidder, for the bid's amount,
///      to this contract, with the hash of this market's address and the bid's terms as its
///      nonce, so equal terms on another deployment are a different signature. Anyone may submit it,
///      the venue's site or the bidder, with the gas paid by the site's paymaster: the signature
///      names the bidder, the amount and every term, so a submitter can only make the exact bid
///      the bidder signed, with the bidder's own money, once. USDC checks the signature, its time window and its nonce: an
///      account with no code by its key, and a contract wallet or an EIP-7702 account through
///      ERC-1271. Until it is used, the bidder can cancel it with USDC's `cancelAuthorization`.
///
///      What the signature covers, and what it leaves to the site and the wallet:
///      - A bid is refused when its signature is good for more than `MAX_SIGNATURE_WINDOW` (one
///        hour) after it is submitted. The contract cannot tell when a signature was made, so a
///        signature with a far deadline still becomes usable in its last hour: the site always
///        asks for a deadline within the hour, and the bidder sees it in the wallet prompt.
///      - The wallet prompt shows this market, the amount, the window and the nonce, a 32-byte
///        number. The venue, slot, wording, length and place-by are inside the nonce and cannot
///        be read there, so the site shows them beside the prompt.
///      - The signature names the bidder's side only. The payout wallet and moderator a bid
///        records are its venue's when the bid is submitted, not when it was signed.
///      - USDC decides whose signature is good. A wallet whose `isValidSignature` accepts
///        anything can be bid for by anyone, on any terms, with its own USDC.
///      - An EIP-7702 account whose delegate has no `isValidSignature` cannot bid, and a
///        signature it made before upgrading is refused once it has upgraded. Nothing is
///        charged.
///      - A bidder cannot take back a held bid before its place-by; the operator can return it,
///        and anyone can withdraw it once place-by has passed.
///
///      Bid money leaves only as a return of a bid never placed (or the unused time of a
///      placement replaced by a newer one), or as payment for its placement, split between
///      REGENT staking and the venue's payout wallet.
///      Nothing is paid out inline: every end records what is owed and `payOut` sends it, so an
///      address USDC refuses to pay can never stop a slot from ending or being replaced.
///
///      Only the owner names a venue's payout wallet, admin and moderator. Each bid keeps the
///      payout wallet its venue named when it was made: a new payout wallet is paid only for
///      bids made after the change, and bids already made pay the wallet stored with them, even
///      when the venue has had to leave it. Nothing can move money already owed to another
///      account: what is owed to an address USDC has blocked waits for USDC to pay it.
///
///      The owner must be a multi-owner Safe. There is no timelock: one stolen owner key can name
///      its own payout wallet, admin, operator and moderator, and take 90% of every bid made
///      after that, in the bid's own block. Bids made before it are paid to the wallets stored
///      with them.
///
///      A placement that should not be showing is cleaned up by replacing it with another bid,
///      never by removal: a removal pays the whole bid to the wallet stored with it, while a
///      replacement pays only the time shown and returns the rest to its bidder.
///
///      USDC sent to this contract other than through a bid is in no record. Only the owner can
///      send it on, with `recoverSurplus`, which pays out the balance above everything owed and so
///      never moves a bidder's, venue's or staking's money.
///
///      There is no upgrade: a new market is a new contract, and pausing this one stops new bids
///      only. Bids already held can still be placed, replace what is showing, be returned or
///      withdrawn, and placements can still be removed and finished. A pause does stop the
///      clean-up bid a replacement needs from being made: while paused, a placement that should
///      not be showing can be replaced only with a bid already held.
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

    /// @notice What a bidder signs for. Its hash is the USDC authorization's nonce; with the
    ///         bidder's address it gives the bid's id.
    /// @param venue The venue's id, such as `keccak256("patchbay.help")`.
    /// @param slot The slot's id within the venue, chosen by the venue (for Patchbay, a forum's
    ///        market and slot number).
    /// @param lane The venue's own lane for the bid; recorded, never read by the contract.
    /// @param wordingHash The exact Offer wording the venue screened.
    /// @param amount USDC base units committed.
    /// @param length The venue's placement length in seconds, which must match its current terms.
    /// @param placeBy After this time the bid can no longer be placed and anyone may withdraw it.
    /// @param salt The bidder's own value, so two otherwise equal bids have different ids.
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
    /// @param admin Names the operator and sets the terms; never the moderator.
    /// @param operator The venue's server key: places and returns bids; never the moderator.
    /// @param moderator Removes placements for policy.
    /// @param payout The wallet paid the venue's share of bids made while it is named.
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
    /// @param payout The venue's payout wallet when the bid was made; it is paid the venue's share.
    struct Bid {
        address bidder;
        uint96 amount;
        bytes32 venue;
        bytes32 slot;
        address payout;
        uint64 placeBy;
        uint64 startsAt;
        uint32 length;
        Status status;
    }

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The longest a bid may wait to be placed: one placement length today, so a bid made
    ///         just after a placement starts can still be placed when it finishes, and no bidder's
    ///         money waits on the operator longer than that.
    uint256 public constant MAX_WAIT = 72 hours;

    /// @notice The latest a bid's signature may still be good, counted from when it is submitted.
    ///         A bid whose `validBefore` is further away is refused, so a signature submitted now
    ///         is spent or dead within this time.
    uint256 public constant MAX_SIGNATURE_WINDOW = 1 hours;

    /// @notice Tag the protocol share is deposited into REGENT staking under.
    // casting to bytes32 is safe because the 13-byte literal fits
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_TAG = bytes32("regent.offers");

    /// @notice The USDC token bids are paid in.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The REGENT revenue staking contract the protocol share is pushed into. It is fixed:
    ///         if it can never take a deposit again, the protocol share stays in this contract.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice Share of a placement's payment sent to REGENT staking, in basis points. The rest
    ///         goes to the venue's payout wallet.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable protocolBps;

    /// @notice While true, new bids are refused. Placing, replacing, returning, withdrawing,
    ///         removing, finishing and payouts never pause.
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
        uint64 placeBy
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
    event SurplusRecovered(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroValue();
    error ShareTooLarge();
    error ContractIsParty();
    error VenueExists();
    error VenueNotFound();
    error NotVenueAdmin();
    error NotOperator();
    error NotModerator();
    error ModeratorNotSeparate();
    error BidsPaused();
    error BelowMinimum();
    error LengthMismatch();
    error PlaceByPassed();
    error PlaceByNotPassed();
    error PlaceByTooFar();
    error SignatureWindowTooLong();
    error BidExists();
    error AmountNotReceived();
    error NotHeld();
    error NotPlaced();
    error NotFinished();
    error NothingOwed();
    error OwnerRequired();
    error NoSurplus();

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
        _checkSeparate(moderator, admin, operator);
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
        _checkSeparate(moderator, v.admin, v.operator);
        v.moderator = moderator;
        emit ModeratorChanged(venue, moderator);
    }

    /// @notice Replaces a venue's admin, for when its key is lost or leaked.
    function setVenueAdmin(bytes32 venue, address admin) external onlyOwner {
        Venue storage v = _venue(venue);
        if (admin == address(0)) revert ZeroAddress();
        _checkSeparate(v.moderator, admin, v.operator);
        v.admin = admin;
        emit VenueAdminChanged(venue, admin);
    }

    /// @notice Names the wallet paid the venue's share of bids made from now on. Bids already
    ///         made keep paying the wallet named when they were made.
    function setPayout(bytes32 venue, address payout) external onlyOwner {
        Venue storage v = _venue(venue);
        _checkPayout(payout);
        v.payout = payout;
        emit PayoutChanged(venue, payout);
    }

    /// @notice Stops or restarts new bids. Placing, replacing with a bid already held, returns,
    ///         withdrawals, removals, finishing and payouts never pause, so money already in keeps
    ///         every way out it had.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Sends `to` the USDC this contract holds above everything it owes: bids held and
    ///         placed, every account's `owed` and the protocol share. That surplus is only USDC
    ///         that arrived other than through a bid, so no bidder's, venue's or staking's money
    ///         can move.
    function recoverSurplus(address to) external nonReentrant onlyOwner returns (uint256 amount) {
        _checkPayout(to);
        amount = usdc.balanceOf(address(this)) - (totalCommitted + totalOwed + revenueOwed);
        // Exactly zero means nothing above the liabilities; any other amount is surplus to send. No
        // time is read here.
        // slither-disable-next-line incorrect-equality,timestamp
        if (amount == 0) revert NoSurplus();
        emit SurplusRecovered(to, amount);
        usdc.safeTransfer(to, amount);
    }

    /// @notice Ownership can be handed on but never given up, so a pause always has someone to lift it.
    function renounceOwnership() public view override onlyOwner {
        revert OwnerRequired();
    }

    // ---------------------------------------------------------- venue admin

    /// @notice Replaces the venue's server key.
    function setOperator(bytes32 venue, address operator) external {
        _onlyVenueAdmin(venue);
        if (operator == address(0)) revert ZeroAddress();
        Venue storage v = venues[venue];
        _checkSeparate(v.moderator, v.admin, operator);
        v.operator = operator;
        emit OperatorChanged(venue, operator);
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

    /// @notice The USDC authorization nonce a bidder signs for `terms` on this market. It names
    ///         this contract, so the same terms on another deployment have another nonce.
    function nonceOf(Terms calldata terms) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), terms));
    }

    /// @notice The id a bid by `bidder` on `terms` is held under.
    function bidIdOf(address bidder, Terms calldata terms) public pure returns (bytes32) {
        return keccak256(abi.encode(bidder, terms));
    }

    /// @notice Holds a bid by `bidder`, funded by the bidder's signed USDC
    ///         `ReceiveWithAuthorization` to this contract for `terms.amount`, valid after
    ///         `validAfter` and before `validBefore`, whose nonce is `nonceOf(terms)`. Anyone may
    ///         submit it while `validBefore` is at most `MAX_SIGNATURE_WINDOW` away. USDC refuses a signature that is not the bidder's, so a zero bidder and
    ///         this contract as the bidder are refused there.
    // slither-disable-next-line timestamp
    function bid(
        Terms calldata terms,
        address bidder,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 bidId) {
        if (paused) revert BidsPaused();
        if (terms.slot == bytes32(0)) revert ZeroValue();
        Venue storage v = _venue(terms.venue);
        if (terms.amount < v.minimum) revert BelowMinimum();
        if (terms.length != v.length) revert LengthMismatch();
        // Times here are hours apart; a block producer's few seconds of leeway changes nothing.
        // forge-lint: disable-next-line(block-timestamp)
        if (terms.placeBy <= block.timestamp) revert PlaceByPassed();
        // forge-lint: disable-next-line(block-timestamp)
        if (terms.placeBy > block.timestamp + MAX_WAIT) revert PlaceByTooFar();
        // forge-lint: disable-next-line(block-timestamp)
        if (validBefore > block.timestamp + MAX_SIGNATURE_WINDOW) revert SignatureWindowTooLong();

        bidId = bidIdOf(bidder, terms);
        if (bids[bidId].status != Status.None) revert BidExists();

        bids[bidId] = Bid({
            bidder: bidder,
            amount: terms.amount,
            venue: terms.venue,
            slot: terms.slot,
            payout: v.payout,
            placeBy: terms.placeBy,
            startsAt: 0,
            length: terms.length,
            status: Status.Held
        });
        totalCommitted += terms.amount;

        _emitBidPlaced(bidId, terms, bidder);
        _receive(terms, bidder, validAfter, validBefore, signature);
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
    ///         Nothing else moves what is owed: while USDC refuses to pay `account`, it waits.
    function payOut(address account) external nonReentrant returns (uint256 amount) {
        amount = owed[account];
        if (amount == 0) revert NothingOwed();
        owed[account] = 0;
        totalOwed -= amount;
        emit PaidOut(account, msg.sender, amount);
        usdc.safeTransfer(account, amount);
    }

    /// @notice Deposits the protocol share owed into REGENT staking. Anyone may call it. While
    ///         staking refuses deposits the share waits here; it has no other way out.
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
        address payout = b.payout;

        b.status = Status.Ended;
        live[b.venue][b.slot] = bytes32(0);
        totalCommitted -= b.amount;
        owed[b.bidder] += returned;
        owed[payout] += venueShare;
        totalOwed += returned + venueShare;
        revenueOwed += protocolShare;

        emit Ended(bidId, reason, paid, returned, protocolShare, venueShare, payout);
    }

    /// @dev Takes a bid's amount through its bidder's signed USDC authorization.
    // Balances are read on either side of the USDC call on purpose, to check the exact amount moved.
    // USDC asks an account with code about its signature with a read-only call, and every function
    // that changes state holds the same guard, so nothing re-enters.
    // slither-disable-next-line reentrancy-balance
    function _receive(
        Terms calldata terms,
        address bidder,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata signature
    ) private {
        uint256 before = usdc.balanceOf(address(this));
        IUSDCReceiveWithAuthorization(address(usdc))
            .receiveWithAuthorization(
                bidder, address(this), terms.amount, validAfter, validBefore, nonceOf(terms), signature
            );
        // USDC moves the exact amount; anything else means the token changed and the bid must fail.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (usdc.balanceOf(address(this)) - before != terms.amount) revert AmountNotReceived();
    }

    function _emitBidPlaced(bytes32 bidId, Terms calldata terms, address bidder) private {
        emit BidPlaced(
            bidId,
            terms.venue,
            terms.slot,
            bidder,
            terms.lane,
            terms.wordingHash,
            terms.amount,
            terms.length,
            terms.placeBy
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

    /// @dev The moderator charges a bid in full, so it is never a key that places or names who places.
    function _checkSeparate(address moderator, address admin, address operator) private pure {
        if (moderator == admin || moderator == operator) revert ModeratorNotSeparate();
    }

    /// @dev USDC refuses to pay its own address, and the staking contract's share is pushed, never
    ///      paid out, so neither may be a payout wallet.
    function _checkPayout(address payout) private view {
        if (payout == address(0)) revert ZeroAddress();
        if (payout == address(this) || payout == address(usdc) || payout == address(staking)) {
            revert ContractIsParty();
        }
    }
}
