// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRegentRevenueStaking} from "./PatchbayEscrow.sol";

/// @notice The USDC function the escrow pulls a bid with: EIP-3009 `receiveWithAuthorization`, in
///         the form that takes the signature as bytes, so a smart-contract wallet (ERC-1271) can bid
///         as well as an ordinary one. USDC requires the caller to be the payee, so only this
///         escrow can redeem an authorization made out to it.
interface IUSDCReceiveWithAuthorization {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
}

/// @title PatchbayOffersEscrow
/// @notice Holds the USDC of each Patchbay Offers bid from the moment it competes until Patchbay
///         settles it. A bid's USDC moves in with one signature from the bidder's wallet, which seals
///         the amount and the bid id. A bid that loses, or is passed over, goes back in full. When a
///         placement ends its amount splits three ways: returned to the bidder, consumed for the time
///         shown, or forfeited on a moderator's removal. Consumed and forfeited USDC is revenue for
///         REGENT stakers. If Patchbay stops settling, anyone may send a bid's USDC back to its
///         bidder 14 days after it went in.
/// @dev The market itself (which bid wins, the pro-rata refund, promotion of a queued bid) lives in
///      Patchbay's records. The contract only holds commitments and pays them out, and enforces:
///      one commitment per bid id, settled at most once; the three parts of a settlement add up to
///      the bid; returned USDC goes only to the address that committed it; revenue goes only to the
///      staking contract fixed at deployment; and it never pays out more than it holds. A
///      compromised operator could misallocate a bid between returned and revenue, but could never
///      send money anywhere but back to the bidder or to that fixed destination.
contract PatchbayOffersEscrow is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Lifecycle of one bid's commitment.
    /// @dev `None` is the zero value, so an untouched bid id is never mistaken for a committed one.
    enum Status {
        None,
        Committed,
        Released,
        Settled,
        Reclaimed
    }

    /// @notice One bid's USDC, held for it.
    /// @param payer The wallet that signed for the bid; everything returned goes back to it.
    /// @param amount The bid, in USDC's 6-decimal base units.
    /// @param status Where the commitment is in its lifecycle.
    /// @param committedAt The block timestamp the USDC arrived, which starts the reclaim delay.
    struct Commitment {
        address payer;
        uint96 amount;
        Status status;
        uint64 committedAt;
    }

    /// @notice How long after a commit anyone may send an unsettled bid back to its bidder.
    /// @dev The longest legitimate commitment is a next-period bid that waits up to 72 hours and then
    ///      runs 72 hours, about six days plus settlement, so this never cuts a live one short.
    uint256 public constant RECLAIM_DELAY = 14 days;

    /// @notice The source tag every push carries, so stakers can see the revenue came from Offers.
    bytes32 public constant SOURCE_TAG = bytes32("patchbay.offers");

    /// @notice The USDC token this escrow holds and pays out.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The REGENT revenue staking contract consumed and forfeited USDC is pushed into.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice The Patchbay server address allowed to commit, release and settle.
    address public operator;

    /// @notice Commitments, keyed by the bid id Patchbay assigns, which is also the USDC
    ///         authorization's nonce.
    mapping(bytes32 bidId => Commitment) public commitments;

    /// @notice Sum of the amounts of all commitments currently in `Committed` status.
    uint256 public totalCommitted;

    /// @notice Consumed and forfeited USDC not yet pushed to the staking contract.
    uint256 public revenueOwed;

    /// @notice Emitted when the owner changes the operator, and once at deployment.
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    /// @notice Emitted when a bid's USDC arrives.
    event Committed(bytes32 indexed bidId, address indexed payer, uint96 amount, uint64 committedAt);

    /// @notice Emitted when a bid that did not win, or was passed over, goes back in full.
    event Released(bytes32 indexed bidId, address indexed payer, uint256 amount);

    /// @notice Emitted when a placement's bid is settled: returned to the payer, the rest kept as revenue.
    event Settled(bytes32 indexed bidId, address indexed payer, uint256 returned, uint256 consumed, uint256 forfeited);

    /// @notice Emitted when an unsettled bid goes back in full after the reclaim delay.
    event Reclaimed(bytes32 indexed bidId, address indexed payer, uint256 amount, address indexed caller);

    /// @notice Emitted when the revenue owed is deposited into the staking contract.
    event RevenuePushed(address indexed caller, uint256 amount);

    /// @notice Thrown when a call that only the operator may make comes from another address.
    error NotOperator();

    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a bid amount is zero.
    error ZeroAmount();

    /// @notice Thrown when the bid id already has a commitment.
    error AlreadyCommitted();

    /// @notice Thrown when a bid is not in `Committed` status.
    error NotCommitted();

    /// @notice Thrown when a settlement's parts do not add up to the bid.
    error PartsDoNotAddUp();

    /// @notice Thrown when a reclaim is attempted before the reclaim delay has passed.
    error ReclaimTooEarly();

    /// @notice Thrown when a push finds no revenue owed.
    error NothingOwed();

    /// @dev Restricts a call to the Patchbay server.
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Deploys the escrow. The staking contract is fixed here and nothing can change it.
    /// @param usdc_ The USDC token address on this chain.
    /// @param staking_ The REGENT revenue staking contract revenue is pushed into.
    /// @param operator_ The Patchbay server address allowed to commit, release and settle.
    /// @param owner_ The address that may later call `setOperator` and transfer ownership.
    constructor(IERC20 usdc_, IRegentRevenueStaking staking_, address operator_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        if (address(staking_) == address(0)) revert ZeroAddress();

        usdc = usdc_;
        staking = staking_;
        _setOperator(operator_);
    }

    /// @notice Points the escrow at a new Patchbay server address.
    /// @dev Owner only. Moves no funds; it only changes who may commit, release and settle.
    /// @param newOperator The new operator address.
    function setOperator(address newOperator) external onlyOwner {
        _setOperator(newOperator);
    }

    /// @notice Moves a bid's USDC in from the bidder's wallet with the authorization they signed.
    /// @dev Operator only, so a bid Patchbay has not accepted never locks anyone's money. The
    ///      authorization is made out to this escrow for `amount`, with `bidId` as its nonce, so the
    ///      bidder's own signature fixes both; Patchbay cannot attribute the money to another bid.
    ///      A second commit of the same bid id reverts here, and USDC refuses a reused nonce.
    /// @param bidId Patchbay's id for the bid; also the authorization nonce.
    /// @param payer The wallet that signed the authorization.
    /// @param amount The bid, in 6-decimal base units.
    /// @param validAfter The authorization's start time, as signed.
    /// @param validBefore The authorization's end time, as signed.
    /// @param signature The bidder's signature over the authorization.
    function commit(
        bytes32 bidId,
        address payer,
        uint96 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata signature
    ) external onlyOperator {
        if (commitments[bidId].status != Status.None) revert AlreadyCommitted();
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint64 committedAt = uint64(block.timestamp);
        commitments[bidId] =
            Commitment({payer: payer, amount: amount, status: Status.Committed, committedAt: committedAt});
        totalCommitted += amount;

        emit Committed(bidId, payer, amount, committedAt);

        IUSDCReceiveWithAuthorization(address(usdc))
            .receiveWithAuthorization(payer, address(this), amount, validAfter, validBefore, bidId, signature);
    }

    /// @notice Sends a committed bid back to its bidder in full: it lost, it was passed over, or it
    ///         was never placed.
    /// @dev Operator only. Promotion of a queued bid is not a release: its commitment carries on.
    /// @param bidId The bid to release.
    function release(bytes32 bidId) external onlyOperator {
        Commitment storage commitment = commitments[bidId];
        if (commitment.status != Status.Committed) revert NotCommitted();

        address payer = commitment.payer;
        uint256 amount = commitment.amount;
        commitment.status = Status.Released;
        totalCommitted -= amount;

        emit Released(bidId, payer, amount);

        usdc.safeTransfer(payer, amount);
    }

    /// @notice Settles the bid behind a placement that has ended: `returned` goes back to the bidder,
    ///         `consumed` and `forfeited` are kept as revenue.
    /// @dev Operator only. The contract checks that the three parts add up to the bid; Patchbay's
    ///      published placement history carries the arithmetic behind them.
    /// @param bidId The bid behind the placement.
    /// @param returned The unused part, back to the bidder.
    /// @param consumed The part for the time shown.
    /// @param forfeited The part kept on a moderator's removal.
    function settle(bytes32 bidId, uint256 returned, uint256 consumed, uint256 forfeited) external onlyOperator {
        Commitment storage commitment = commitments[bidId];
        if (commitment.status != Status.Committed) revert NotCommitted();

        uint256 amount = commitment.amount;
        if (returned + consumed + forfeited != amount) revert PartsDoNotAddUp();

        address payer = commitment.payer;
        commitment.status = Status.Settled;
        totalCommitted -= amount;
        revenueOwed += consumed + forfeited;

        emit Settled(bidId, payer, returned, consumed, forfeited);

        if (returned != 0) usdc.safeTransfer(payer, returned);
    }

    /// @notice Sends a bid still unsettled 14 days after it went in back to its bidder, in full.
    /// @dev Anyone may call this: the money can only go to the bidder, and the deadline is the
    ///      contract's own, so getting it back never depends on Patchbay running.
    /// @param bidId The bid to reclaim.
    function reclaim(bytes32 bidId) external {
        Commitment storage commitment = commitments[bidId];
        if (commitment.status != Status.Committed) revert NotCommitted();
        if (block.timestamp < commitment.committedAt + RECLAIM_DELAY) revert ReclaimTooEarly();

        address payer = commitment.payer;
        uint256 amount = commitment.amount;
        commitment.status = Status.Reclaimed;
        totalCommitted -= amount;

        emit Reclaimed(bidId, payer, amount, msg.sender);

        usdc.safeTransfer(payer, amount);
    }

    /// @notice Deposits all the revenue owed into the REGENT revenue staking contract, tagged
    ///         `patchbay.offers`.
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
        staking.depositUSDC(amount, SOURCE_TAG, bytes32(0));
    }

    /// @dev Sets the operator and emits `OperatorChanged`; rejects the zero address so the escrow
    ///      always has a live operator.
    /// @param newOperator The new operator address.
    function _setOperator(address newOperator) private {
        if (newOperator == address(0)) revert ZeroAddress();

        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }
}
