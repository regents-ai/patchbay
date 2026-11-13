// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRegentRevenueStaking} from "./PatchbayEscrow.sol";

/// @title IAgentOfferMarket
/// @notice One publisher's market for reserved, fixed-term Offer placements, paid in USDC.
/// @dev A publisher is the operator that actually shows Offers to agents and is paid for it. A
///      placement is one surface the publisher sells: a number of slots, each rented for a fixed
///      term at a price no lower than the placement's floor. While a lease is live a buyer may take
///      its slot by paying at least the placement's step more than the lease paid; the replaced
///      buyer is credited the unused part of its payment, pro rata to the seconds left. Earned money
///      is credited only when a lease ends (bought out, run out or terminated), split between the
///      publisher's payout wallet and the protocol fee kept for REGENT stakers. Every credit is
///      taken by its owner with `claim`; nothing is ever pushed to a buyer or a publisher.
///
///      Three slots, three days and a 10% step are Patchbay's own settings, not rules of the market.
///      Placement and source ids are this market's own; another market's id 1 is another
///      placement. The ids, the terms and the admission policy hash a placement was created with
///      never change. To change terms the publisher terminates a placement, or lets its leases run
///      out, and creates a new one. The market cannot tell that two placements are the same place on
///      a page, so the publisher's own server must not sell a replacement while the old one is open.
interface IAgentOfferMarket {
    /// @notice What the factory gives a new market, once.
    /// @param usdc The USDC token every price is paid in.
    /// @param publisher The address that creates and terminates placements and signs admissions. An
    ///        ERC-1271 contract wallet is supported.
    /// @param payout The wallet credited the publisher's share of everything earned. Fixed for the
    ///        market's life: a stolen publisher key cannot redirect it.
    /// @param staking The REGENT revenue staking contract the protocol fee is pushed into.
    /// @param feeBps The protocol fee on earned money, in basis points.
    struct Init {
        IERC20 usdc;
        address publisher;
        address payout;
        IRegentRevenueStaking staking;
        uint16 feeBps;
    }

    /// @notice The terms of a placement, fixed when it is created.
    /// @param capacity Number of slots, each rented separately. Patchbay uses 3.
    /// @param durationSeconds Length of every lease. Patchbay uses 72 hours.
    /// @param minBumpBps How much more than a live lease paid a buyout must pay, in basis points.
    ///        Patchbay uses 1_000 (10%).
    /// @param floorUSDC The least a lease on an empty or run-out slot costs, in USDC base units
    ///        (6 decimals), not whole dollars.
    /// @param policyHash The publisher's versioned admission policy. Every admission signed for this
    ///        placement names it, so a policy change needs a new placement.
    struct PlacementTerms {
        uint16 capacity;
        uint32 durationSeconds;
        uint16 minBumpBps;
        uint128 floorUSDC;
        bytes32 policyHash;
    }

    /// @notice A placement and whether it has been terminated.
    /// @param sourceId The verified publisher origin (a site) the placement belongs to.
    /// @param terms The terms it was created with.
    /// @param terminatedAt The moment the publisher terminated it; zero while it is open. Every lease
    ///        in it is settled as if it ended then, or at its own end if that came first.
    struct Placement {
        bytes32 sourceId;
        PlacementTerms terms;
        uint64 terminatedAt;
    }

    /// @notice One slot's current lease.
    /// @param buyer The address that paid; it is credited any refund.
    /// @param campaignId The advertiser-signed campaign manifest hash the slot shows.
    /// @param paidUSDC What the lease paid, held by the market until the lease is settled. Zero
    ///        when the slot is empty or its last lease has been settled.
    /// @param startsAt The moment the lease began.
    /// @param endsAt The moment it runs out: `startsAt` plus the placement's duration. The lease is
    ///        live while the placement is open and `block.timestamp < endsAt`.
    /// @param nonce How many leases this slot has ever sold. It only ever goes up, and it stays
    ///        after a lease is settled, so a purchase or admission naming an old value never lands.
    struct Lease {
        address buyer;
        bytes32 campaignId;
        uint128 paidUSDC;
        uint64 startsAt;
        uint64 endsAt;
        uint64 nonce;
    }

    /// @notice A buyer's order for one slot.
    /// @param placementId The placement to buy in.
    /// @param slot The slot, below the placement's capacity.
    /// @param campaignId The campaign the slot will show; not zero.
    /// @param amountUSDC What the buyer pays, at least the slot's current minimum.
    /// @param expectedLeaseNonce The slot's `nonce` the buyer saw. If anyone buys the slot first the
    ///        nonce has moved and this purchase reverts, moving nothing.
    /// @param deadline The last second the purchase, and the admission signed for it, may land.
    struct Purchase {
        uint256 placementId;
        uint16 slot;
        bytes32 campaignId;
        uint128 amountUSDC;
        uint64 expectedLeaseNonce;
        uint64 deadline;
    }

    /// @notice Why a lease was settled.
    enum SettleReason {
        BoughtOut,
        Expired,
        Terminated
    }

    /// @notice Emitted once, when the factory sets the market up.
    event MarketInitialized(
        address indexed publisher, address indexed payout, address usdc, address staking, uint16 feeBps
    );

    /// @notice Emitted when the publisher creates a placement. The metadata URI is only ever
    ///         recorded here.
    event PlacementCreated(
        uint256 indexed placementId,
        bytes32 indexed sourceId,
        uint16 capacity,
        uint32 durationSeconds,
        uint16 minBumpBps,
        uint128 floorUSDC,
        bytes32 policyHash,
        string metadataURI
    );

    /// @notice Emitted when the publisher terminates a placement. No lease in it is settled yet;
    ///         `settleTerminated` settles each slot from this moment.
    event PlacementTerminated(uint256 indexed placementId, uint64 terminatedAt);

    /// @notice Emitted when a lease is bought. The buyer's payment is now held for this lease.
    event LeasePurchased(
        uint256 indexed placementId,
        uint16 indexed slot,
        address indexed buyer,
        bytes32 campaignId,
        uint128 paidUSDC,
        uint64 startsAt,
        uint64 endsAt,
        uint64 nonce
    );

    /// @notice Emitted when a lease is settled. `refundUSDC` is credited to `buyer`, `publisherUSDC`
    ///         to the payout wallet, and `feeUSDC` added to the revenue owed to staking; the three
    ///         add up to exactly what the lease paid.
    /// @param settledAt The moment the lease is charged up to: the buyout, its own end, or the
    ///        placement's termination, whichever applies.
    event LeaseSettled(
        uint256 indexed placementId,
        uint16 indexed slot,
        address indexed buyer,
        uint64 nonce,
        SettleReason reason,
        uint64 settledAt,
        uint256 refundUSDC,
        uint256 publisherUSDC,
        uint256 feeUSDC
    );

    /// @notice Emitted when an account takes its credit, sent to `recipient`.
    event Claimed(address indexed account, address indexed recipient, uint256 amountUSDC);

    /// @notice Emitted when the revenue owed is deposited into the staking contract.
    event RevenuePushed(address indexed caller, uint256 amountUSDC);

    /// @notice Thrown by `initialize` for a zero address, a payout wallet that is the market itself,
    ///         or a fee above `MAX_FEE_BPS`.
    error InvalidConfiguration();

    /// @notice Thrown when a call only the publisher may make comes from another address.
    error NotPublisher();

    /// @notice Thrown when a placement's source, policy or terms are zero or out of bounds.
    error InvalidTerms();

    /// @notice Thrown when a placement id was never created.
    error UnknownPlacement();

    /// @notice Thrown when a slot is not below the placement's capacity.
    error UnknownSlot();

    /// @notice Thrown when a placement has been terminated: by `buy`, `settleExpired`,
    ///         `minimumPrice`, and a second `terminatePlacement`.
    error AlreadyTerminated();

    /// @notice Thrown by `settleTerminated` on a placement that is still open.
    error NotTerminated();

    /// @notice Thrown when a purchase lands after its deadline.
    error PurchaseExpired();

    /// @notice Thrown when a purchase names a campaign id of zero.
    error ZeroCampaign();

    /// @notice Thrown when the slot's lease nonce is no longer the one the purchase expected.
    /// @param currentNonce The slot's nonce now.
    error StaleLeaseNonce(uint64 currentNonce);

    /// @notice Thrown when the admission is not the publisher's signature over exactly this purchase
    ///         by this buyer.
    error InvalidPermit();

    /// @notice Thrown when a purchase pays less than the slot's current minimum.
    /// @param minimumUSDC The least the slot costs now.
    error AmountBelowMinimum(uint256 minimumUSDC);

    /// @notice Thrown by `settleExpired` while the slot's lease is still live.
    error LeaseLive();

    /// @notice Thrown when a claim or a push finds nothing owed.
    error NothingOwed();

    /// @notice Thrown when a claim names the zero address or the market itself as recipient.
    error InvalidRecipient();

    /// @notice Sets the market up. The factory calls it in the same transaction that creates the
    ///         market; it can never run twice, and never on the implementation itself.
    function initialize(Init calldata config) external;

    /// @notice Creates a placement whose terms never change. Publisher only.
    /// @param sourceId The verified site the placement belongs to; not zero.
    /// @param terms Capacity, duration, step, floor and policy; see `PlacementTerms`.
    /// @param metadataURI Where the placement is described; recorded in the event only.
    /// @return placementId The new placement's id, counting from 1.
    function createPlacement(bytes32 sourceId, PlacementTerms calldata terms, string calldata metadataURI)
        external
        returns (uint256 placementId);

    /// @notice Pays for a fresh full-term lease on one slot, settling the slot's previous lease.
    /// @dev Anyone may buy, with the publisher's admission for exactly this purchase by the caller,
    ///      and an approval for `amountUSDC`. The admission proves the publisher admitted the
    ///      campaign; it proves nothing about the agents that will see it.
    /// @param purchase The order; see `Purchase`.
    /// @param eligibilityPermit The publisher's EIP-712 signature (or ERC-1271 approval) of
    ///        `EligibilityPermit` for this purchase and buyer.
    function buy(Purchase calldata purchase, bytes calldata eligibilityPermit) external;

    /// @notice One slot's lease. A settled or never-sold slot reads all zeros but its nonce.
    function getLease(uint256 placementId, uint16 slot) external view returns (Lease memory);

    /// @notice One placement, with its terms and termination time.
    function getPlacement(uint256 placementId) external view returns (Placement memory);

    /// @notice The least a purchase of this slot must pay now: the placement's floor when the slot
    ///         is empty or its lease has run out, and the lease's payment plus the placement's step,
    ///         rounded up, while it is live.
    function minimumPrice(uint256 placementId, uint16 slot) external view returns (uint256);

    /// @notice The EIP-712 digest the publisher signs to admit `buyer`'s `purchase`.
    function eligibilityDigest(Purchase calldata purchase, address buyer) external view returns (bytes32);

    /// @notice Settles a slot's lease that has run out on an open placement: everything it paid is
    ///         earned. Anyone may call it. An empty or already settled slot is left as it is.
    function settleExpired(uint256 placementId, uint16 slot) external;

    /// @notice Closes a placement to buying. Publisher only. Each live lease is then refunded pro
    ///         rata from this moment by `settleTerminated`, one slot per call.
    function terminatePlacement(uint256 placementId) external;

    /// @notice Settles a slot's lease on a terminated placement as of the termination, or its own
    ///         end if that came first. Anyone may call it. An empty or already settled slot is left
    ///         as it is.
    function settleTerminated(uint256 placementId, uint16 slot) external;

    /// @notice Sends all of the caller's credit to `recipient`.
    /// @return amountUSDC What was sent.
    function claim(address recipient) external returns (uint256 amountUSDC);

    /// @notice What `account` may take with `claim`: refunds and, for the payout wallet, earnings.
    function claimable(address account) external view returns (uint256);

    /// @notice Deposits all the revenue owed into the REGENT revenue staking contract. Anyone may
    ///         call it.
    /// @return amountUSDC What was pushed.
    function pushRevenue() external returns (uint256 amountUSDC);
}
