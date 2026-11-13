// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IRegentRevenueStaking} from "./PatchbayEscrow.sol";
import {IAgentOfferMarket} from "./IAgentOfferMarket.sol";

/// @title AgentOfferMarket
/// @notice One publisher's market for reserved, fixed-term Offer placements, paid in USDC. See
///         `IAgentOfferMarket` for the model.
/// @dev Deployed once as an implementation by `AgentOfferFactory`, then cloned once per publisher.
///      The implementation can never be initialized, and each clone is initialized exactly once,
///      in the factory call that creates it. There is no upgrade, owner, pause or sweep.
///
///      Money. A purchase is held for its lease until the lease is settled; settlement only ever
///      credits: the unused part to the buyer, the earned part to the payout wallet less the
///      protocol fee, which is kept in `revenueOwed`. Every credit leaves only through its owner's
///      `claim`, and the fee only through `pushRevenue` into the fixed staking contract, so a frozen
///      or failing wallet can never block anyone else's purchase, settlement or claim. The market
///      keeps its books by amounts, never by reading its balance:
///      `usdc.balanceOf(market) >= totalLeaseDeposits + totalClaimable + revenueOwed` at all times,
///      with equality unless someone sends USDC straight to the market (which then stays there).
///
///      Arithmetic. Refunds round down to the base unit, so the old buyer never gets more than the
///      unused share; the buyout minimum rounds up, so a buyout always beats the step. Every product
///      fits easily in uint256: payments are uint128, the step factor is at most 2 * 10_000 and the
///      seconds left at most `MAX_DURATION`.
///
///      Time is counted in seconds of `block.timestamp`, never in blocks.
contract AgentOfferMarket is IAgentOfferMarket, Initializable, ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The highest protocol fee a market can be given: a fifth of what is earned, so a
    ///         publisher always keeps at least 80%.
    uint16 public constant MAX_FEE_BPS = 2_000;

    /// @notice The longest lease a placement may sell.
    uint32 public constant MAX_DURATION = 365 days;

    /// @notice The largest buyout step a placement may set: a buyout never has to pay more than
    ///         twice what the live lease paid.
    uint16 public constant MAX_BUMP_BPS = 10_000;

    /// @notice The source tag every push carries, so stakers can see the revenue came from here.
    // casting to 'bytes32' is safe because the 12-character literal fits in 32 bytes
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_TAG = bytes32("agent.offers");

    /// @notice The EIP-712 type the publisher signs to admit one purchase. The domain adds this
    ///         market's address and the chain id.
    bytes32 public constant ELIGIBILITY_TYPEHASH = keccak256(
        "EligibilityPermit(uint256 placementId,uint16 slot,bytes32 sourceId,address buyer,bytes32 campaignId,bytes32 policyHash,uint128 amountUSDC,uint64 expectedLeaseNonce,uint64 deadline)"
    );

    /// @notice The USDC token every price is paid in.
    IERC20 public usdc;

    /// @notice The address that creates and terminates placements and signs admissions.
    address public publisher;

    /// @notice The wallet credited the publisher's share of everything earned. Never changes.
    address public payout;

    /// @notice The REGENT revenue staking contract the protocol fee is pushed into. Never changes.
    IRegentRevenueStaking public staking;

    /// @notice The protocol fee on earned money, in basis points. Never changes.
    uint16 public feeBps;

    /// @notice Number of placements created; ids run from 1 to this.
    uint256 public placementCount;

    /// @notice What every unsettled lease paid, together.
    uint256 public totalLeaseDeposits;

    /// @notice Every account's credit, together.
    uint256 public totalClaimable;

    /// @notice Protocol fee earned and not yet pushed to the staking contract.
    uint256 public revenueOwed;

    /// @inheritdoc IAgentOfferMarket
    mapping(address account => uint256 amountUSDC) public claimable;

    /// @dev Every placement, keyed by id. Read with `getPlacement`.
    mapping(uint256 placementId => Placement) private _placements;

    /// @dev Every slot's lease. Read with `getLease`.
    mapping(uint256 placementId => mapping(uint16 slot => Lease)) private _leases;

    /// @dev Restricts a call to the publisher.
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyPublisher() {
        if (msg.sender != publisher) revert NotPublisher();
        _;
    }

    /// @notice Deploys the implementation every market is a clone of, and locks it so it can never
    ///         be initialized itself. The EIP-712 name and version live in its code and so are shared
    ///         by every clone; the domain's address and chain id are always the clone's own.
    constructor() EIP712("AgentOfferMarket", "1") {
        _disableInitializers();
    }

    /// @inheritdoc IAgentOfferMarket
    function initialize(Init calldata config) external initializer {
        if (
            address(config.usdc) == address(0) || config.publisher == address(0) || config.payout == address(0)
                || config.payout == address(this) || address(config.staking) == address(0)
                || config.feeBps > MAX_FEE_BPS
        ) revert InvalidConfiguration();

        usdc = config.usdc;
        publisher = config.publisher;
        payout = config.payout;
        staking = config.staking;
        feeBps = config.feeBps;

        // No call is made here; the `initializer` modifier only reads this market's own code size.
        // forge-lint: disable-start(reentrancy-events)
        emit MarketInitialized(
            config.publisher, config.payout, address(config.usdc), address(config.staking), config.feeBps
        );
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @inheritdoc IAgentOfferMarket
    /// @dev Bounds: a source and policy that are not zero, at least one slot, a duration from one
    ///      second to `MAX_DURATION`, a step from 1 to `MAX_BUMP_BPS` basis points, and a floor above
    ///      zero. Capacity is never looped over, so its only bound is its type.
    function createPlacement(bytes32 sourceId, PlacementTerms calldata terms, string calldata metadataURI)
        external
        onlyPublisher
        returns (uint256 placementId)
    {
        if (
            sourceId == bytes32(0) || terms.policyHash == bytes32(0) || terms.capacity == 0
                || terms.durationSeconds == 0 || terms.durationSeconds > MAX_DURATION || terms.minBumpBps == 0
                || terms.minBumpBps > MAX_BUMP_BPS || terms.floorUSDC == 0
        ) revert InvalidTerms();

        placementId = ++placementCount;
        Placement storage placement = _placements[placementId];
        placement.sourceId = sourceId;
        placement.terms = terms;

        emit PlacementCreated(
            placementId,
            sourceId,
            terms.capacity,
            terms.durationSeconds,
            terms.minBumpBps,
            terms.floorUSDC,
            terms.policyHash,
            metadataURI
        );
    }

    /// @inheritdoc IAgentOfferMarket
    /// @dev Checks the placement, slot, deadline, campaign, nonce, admission and price in that
    ///      order, settles the slot's previous lease (a buyout of a live lease as of now, or a run-out
    ///      one in full), writes the new lease, and only then pulls the payment. A purchase at the
    ///      very second a lease ends meets a run-out lease: the floor applies and nothing is refunded.
    ///      Buying out one's own lease is allowed and works like any buyout.
    function buy(Purchase calldata purchase, bytes calldata eligibilityPermit) external nonReentrant {
        Placement storage placement = _openPlacement(purchase.placementId);
        Lease storage lease = _lease(placement, purchase.placementId, purchase.slot);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > purchase.deadline) revert PurchaseExpired();
        if (purchase.campaignId == bytes32(0)) revert ZeroCampaign();
        uint64 nonce = lease.nonce;
        if (nonce != purchase.expectedLeaseNonce) revert StaleLeaseNonce(nonce);
        if (!SignatureChecker.isValidSignatureNowCalldata(
                publisher, _eligibilityDigest(purchase, placement, msg.sender), eligibilityPermit
            )) revert InvalidPermit();
        uint256 minimum = _minimum(placement, lease);
        if (purchase.amountUSDC < minimum) revert AmountBelowMinimum(minimum);

        uint64 startsAt = SafeCast.toUint64(block.timestamp);
        if (lease.paidUSDC != 0) {
            if (_isLive(lease)) {
                _settle(purchase.placementId, purchase.slot, lease, startsAt, SettleReason.BoughtOut);
            } else {
                _settle(purchase.placementId, purchase.slot, lease, lease.endsAt, SettleReason.Expired);
            }
        }

        uint64 endsAt = startsAt + placement.terms.durationSeconds;
        lease.buyer = msg.sender;
        lease.campaignId = purchase.campaignId;
        lease.paidUSDC = purchase.amountUSDC;
        lease.startsAt = startsAt;
        lease.endsAt = endsAt;
        lease.nonce = nonce + 1;
        totalLeaseDeposits += purchase.amountUSDC;

        // The only call before this point is the ERC-1271 check, a static call that cannot change
        // state, and the whole function is nonReentrant.
        // forge-lint: disable-start(reentrancy-events)
        emit LeasePurchased(
            purchase.placementId,
            purchase.slot,
            msg.sender,
            purchase.campaignId,
            purchase.amountUSDC,
            startsAt,
            endsAt,
            nonce + 1
        );
        // forge-lint: disable-end(reentrancy-events)

        usdc.safeTransferFrom(msg.sender, address(this), purchase.amountUSDC);
    }

    /// @inheritdoc IAgentOfferMarket
    function settleExpired(uint256 placementId, uint16 slot) external nonReentrant {
        Placement storage placement = _openPlacement(placementId);
        Lease storage lease = _lease(placement, placementId, slot);
        if (lease.paidUSDC == 0) return;
        if (_isLive(lease)) revert LeaseLive();

        _settle(placementId, slot, lease, lease.endsAt, SettleReason.Expired);
    }

    /// @inheritdoc IAgentOfferMarket
    /// @dev Only records the moment. Settling is per slot, so termination never loops over a
    ///      placement's capacity, however large.
    function terminatePlacement(uint256 placementId) external nonReentrant onlyPublisher {
        Placement storage placement = _openPlacement(placementId);
        uint64 terminatedAt = SafeCast.toUint64(block.timestamp);
        placement.terminatedAt = terminatedAt;

        emit PlacementTerminated(placementId, terminatedAt);
    }

    /// @inheritdoc IAgentOfferMarket
    function settleTerminated(uint256 placementId, uint16 slot) external nonReentrant {
        Placement storage placement = _placement(placementId);
        uint64 terminatedAt = placement.terminatedAt;
        if (terminatedAt == 0) revert NotTerminated();
        Lease storage lease = _lease(placement, placementId, slot);
        if (lease.paidUSDC == 0) return;

        uint64 endsAt = lease.endsAt;
        _settle(placementId, slot, lease, endsAt < terminatedAt ? endsAt : terminatedAt, SettleReason.Terminated);
    }

    /// @inheritdoc IAgentOfferMarket
    /// @dev Takes only the caller's own credit. The recipient may be any address but the zero
    ///      address and the market, so a wallet USDC has frozen can still have its credit sent to
    ///      another of its own.
    function claim(address recipient) external nonReentrant returns (uint256 amountUSDC) {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        amountUSDC = claimable[msg.sender];
        if (amountUSDC == 0) revert NothingOwed();
        claimable[msg.sender] = 0;
        totalClaimable -= amountUSDC;

        emit Claimed(msg.sender, recipient, amountUSDC);

        usdc.safeTransfer(recipient, amountUSDC);
    }

    /// @inheritdoc IAgentOfferMarket
    /// @dev The money can only go to the fixed staking contract, tagged `agent.offers` with this
    ///      market's address as the reference. While that contract is paused the deposit reverts and
    ///      the revenue stays owed; nothing else waits on it. The staking contract is trusted to pull
    ///      exactly the amount it is approved for, as USDC's `transferFrom` does.
    function pushRevenue() external nonReentrant returns (uint256 amountUSDC) {
        amountUSDC = revenueOwed;
        if (amountUSDC == 0) revert NothingOwed();
        revenueOwed = 0;

        emit RevenuePushed(msg.sender, amountUSDC);

        usdc.forceApprove(address(staking), amountUSDC);
        // The staking contract records what it received itself; USDC moves the exact amount.
        // slither-disable-next-line unused-return
        staking.depositUSDC(amountUSDC, SOURCE_TAG, bytes32(uint256(uint160(address(this))))); // forge-lint: disable-line(unused-return)
    }

    /// @inheritdoc IAgentOfferMarket
    function getLease(uint256 placementId, uint16 slot) external view returns (Lease memory) {
        return _leases[placementId][slot];
    }

    /// @inheritdoc IAgentOfferMarket
    function getPlacement(uint256 placementId) external view returns (Placement memory) {
        return _placements[placementId];
    }

    /// @inheritdoc IAgentOfferMarket
    function minimumPrice(uint256 placementId, uint16 slot) external view returns (uint256) {
        Placement storage placement = _openPlacement(placementId);
        return _minimum(placement, _lease(placement, placementId, slot));
    }

    /// @inheritdoc IAgentOfferMarket
    function eligibilityDigest(Purchase calldata purchase, address buyer) external view returns (bytes32) {
        return _eligibilityDigest(purchase, _placement(purchase.placementId), buyer);
    }

    /// @dev Charges a lease up to `settledAt`, credits the three parts, and clears the lease but its
    ///      nonce. `settledAt` is never before the lease began nor after it ends, so the seconds left
    ///      are at most the duration and the refund at most the payment. The refund rounds down and
    ///      the fee rounds down, so the payout wallet gets the rounding of the fee and the three parts
    ///      add up to the payment exactly.
    function _settle(uint256 placementId, uint16 slot, Lease storage lease, uint64 settledAt, SettleReason reason)
        private
    {
        uint256 paid = lease.paidUSDC;
        uint256 refund = Math.mulDiv(paid, lease.endsAt - settledAt, lease.endsAt - lease.startsAt);
        uint256 earned = paid - refund;
        uint256 fee = Math.mulDiv(earned, feeBps, BPS);
        address buyer = lease.buyer;

        totalLeaseDeposits -= paid;
        claimable[buyer] += refund;
        claimable[payout] += earned - fee;
        totalClaimable += paid - fee;
        revenueOwed += fee;

        // Reached from `buy` after its ERC-1271 static call, which cannot change state, and only
        // inside nonReentrant functions.
        // forge-lint: disable-next-line(reentrancy-events)
        emit LeaseSettled(placementId, slot, buyer, lease.nonce, reason, settledAt, refund, earned - fee, fee);

        lease.buyer = address(0);
        lease.campaignId = bytes32(0);
        lease.paidUSDC = 0;
        lease.startsAt = 0;
        lease.endsAt = 0;
    }

    /// @dev The EIP-712 digest of an admission. The placement's own source and policy are bound, so
    ///      a signature for one placement or policy never admits a purchase in another.
    function _eligibilityDigest(Purchase calldata purchase, Placement storage placement, address buyer)
        private
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ELIGIBILITY_TYPEHASH,
                    purchase.placementId,
                    purchase.slot,
                    placement.sourceId,
                    buyer,
                    purchase.campaignId,
                    placement.terms.policyHash,
                    purchase.amountUSDC,
                    purchase.expectedLeaseNonce,
                    purchase.deadline
                )
            )
        );
    }

    /// @dev The least a purchase of `lease`'s slot must pay now.
    function _minimum(Placement storage placement, Lease storage lease) private view returns (uint256) {
        if (lease.paidUSDC != 0 && _isLive(lease)) {
            return Math.mulDiv(lease.paidUSDC, BPS + placement.terms.minBumpBps, BPS, Math.Rounding.Ceil);
        }
        return placement.terms.floorUSDC;
    }

    /// @dev Whether a lease's term is still running. A placement's termination is checked
    ///      separately by every caller.
    function _isLive(Lease storage lease) private view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < lease.endsAt;
    }

    /// @dev A placement that exists.
    function _placement(uint256 placementId) private view returns (Placement storage placement) {
        placement = _placements[placementId];
        if (placement.terms.durationSeconds == 0) revert UnknownPlacement();
    }

    /// @dev A placement that exists and has not been terminated.
    function _openPlacement(uint256 placementId) private view returns (Placement storage placement) {
        placement = _placement(placementId);
        if (placement.terminatedAt != 0) revert AlreadyTerminated();
    }

    /// @dev A slot's lease, after checking the slot is below the placement's capacity.
    function _lease(Placement storage placement, uint256 placementId, uint16 slot)
        private
        view
        returns (Lease storage)
    {
        if (slot >= placement.terms.capacity) revert UnknownSlot();
        return _leases[placementId][slot];
    }
}
