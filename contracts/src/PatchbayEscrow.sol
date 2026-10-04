// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice The one function of the REGENT revenue staking contract the escrow pays into.
interface IRegentRevenueStaking {
    /// @notice Pulls `amount` USDC from the caller and credits it to REGENT stakers as revenue.
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}

/// @title PatchbayEscrow
/// @notice Holds the USDC a Patchbay asker pays for a pay-to-special forum post until the asker
///         picks a correct answer, then pays the winner 90% and keeps 10% as Regents Labs revenue
///         for REGENT stakers. An answer the asker never picks is not held forever: 30 days after a
///         post is funded anyone may refund it, which pays the asker back 90% and keeps the same
///         10%. Anyone may push the revenue kept into the REGENT revenue staking contract.
/// @dev The asker pays over x402, whose settlement is a plain USDC transfer to this contract, so a
///      deposit arrives with no indication of which post it belongs to. The Patchbay server (the
///      operator) attributes each confirmed deposit to a post id with `credit`, and later calls
///      `release`. The refund is the one call the operator does not gate: after the refund delay
///      anybody may make it, and the money can only go back to the payer the credit recorded, so
///      an asker is never left waiting on Patchbay to be running. Revenue is kept rather than
///      deposited during a payout, so a paused staking contract never holds up a winner or an
///      asker; it only holds up `pushRevenue`. The contract is an operator-trusted ledger with
///      an immutable split:
///      it enforces that the operator can never attribute more than the USDC actually held, that a
///      post pays out at most once, and that every payout follows the fixed 90/10 split. It does
///      not, and cannot, verify that the operator attributed a deposit to the right post or
///      released it to the right winner.
contract PatchbayEscrow is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Lifecycle of a single pay-to-special post.
    /// @dev `None` is the zero value, so an untouched post id is never mistaken for a funded one.
    enum Status {
        None,
        Funded,
        Released,
        Refunded
    }

    /// @notice A deposit that the operator has attributed to one post id.
    /// @param payer The address the asker paid from; the refund destination.
    /// @param amount The attributed USDC amount, in USDC's 6-decimal base units.
    /// @param status Where the post is in its lifecycle.
    /// @param fundedAt The block timestamp the credit was recorded at, which starts the refund delay.
    struct Post {
        address payer;
        uint96 amount;
        Status status;
        uint64 fundedAt;
    }

    /// @notice Share of a post's amount paid to its recipient, in basis points.
    /// @dev The recipient is the winning answer on a release, and the asker who paid on a refund.
    ///      Taking a post off the board costs the asker the same fee that answering it would have,
    ///      so a refund is never the cheaper way out of a bounty.
    uint256 public constant RECIPIENT_BPS = 9000;

    /// @notice Share of a post's amount kept as revenue for REGENT stakers, in basis points.
    uint256 public constant REVENUE_BPS = 1000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice How long after funding a post must wait before anyone may refund it.
    uint256 public constant REFUND_DELAY = 30 days;

    /// @notice The USDC token this escrow holds and pays out.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The REGENT revenue staking contract the revenue share is pushed into.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice The source tag every push carries, so stakers can see the revenue came from here.
    bytes32 public constant SOURCE_TAG = bytes32("patchbay.escrow");

    /// @notice The Patchbay server address allowed to credit and release.
    address public operator;

    /// @notice Attributed deposits, keyed by the post id the server assigns.
    mapping(bytes32 postId => Post) public posts;

    /// @notice Sum of the amounts of all posts currently in `Funded` status.
    /// @dev USDC held beyond this figure and `revenueOwed` is unattributed: deposits that have
    ///      arrived but have not been credited yet. It stays in the contract until the operator
    ///      credits it.
    uint256 public totalCredited;

    /// @notice Revenue share of every release and refund not yet pushed to the staking contract.
    uint256 public revenueOwed;

    /// @notice Emitted when the owner changes the operator, and once at deployment.
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    /// @notice Emitted when the operator attributes a deposit to a post id.
    event Credited(bytes32 indexed postId, address indexed payer, uint96 amount, uint64 fundedAt);

    /// @notice Emitted when the operator releases a funded post to a winning answer.
    event Released(bytes32 indexed postId, address indexed winner, uint256 winnerAmount, uint256 revenueAmount);

    /// @notice Emitted when a funded post is refunded to its payer after the refund delay.
    event Refunded(bytes32 indexed postId, address indexed payer, uint256 payerAmount, uint256 revenueAmount);

    /// @notice Emitted when the revenue owed is deposited into the staking contract.
    event RevenuePushed(address indexed caller, uint256 amount);

    /// @notice Thrown when a call that only the operator may make comes from another address.
    error NotOperator();

    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a credited amount is zero.
    error ZeroAmount();

    /// @notice Thrown when the post id has already been credited.
    error PostAlreadyCredited();

    /// @notice Thrown when a post is not in `Funded` status.
    error PostNotFunded();

    /// @notice Thrown when a credit would attribute more USDC than the contract holds.
    error AmountExceedsBalance();

    /// @notice Thrown when a release names the payer as the winner.
    error WinnerIsPayer();

    /// @notice Thrown when the escrow's own address is named as a payer or a winner.
    error EscrowIsParty();

    /// @notice Thrown when a refund is attempted before the refund delay has passed.
    error RefundTooEarly();

    /// @notice Thrown when a push finds no revenue owed.
    error NothingOwed();

    /// @dev Restricts a call to the Patchbay server. One check, two call sites; kept inline so
    ///      the access rule is readable at the point it is enforced.
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Deploys the escrow. `owner_` is the owner from construction; a Safe can hold that
    ///         role in the same deploy receipt. Ownable2Step still applies to later handovers.
    /// @param usdc_ The USDC token address on this chain.
    /// @param staking_ The REGENT revenue staking contract the 10% revenue share is pushed into.
    /// @param operator_ The Patchbay server address allowed to credit and release.
    /// @param owner_ The address that may later call `setOperator` and transfer ownership.
    constructor(IERC20 usdc_, IRegentRevenueStaking staking_, address operator_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        if (address(staking_) == address(0)) revert ZeroAddress();

        usdc = usdc_;
        staking = staking_;
        _setOperator(operator_);
    }

    /// @notice Points the escrow at a new Patchbay server address.
    /// @dev Owner only. Moves no funds; it only changes who may call credit and release.
    /// @param newOperator The new operator address.
    function setOperator(address newOperator) external onlyOwner {
        _setOperator(newOperator);
    }

    /// @notice Attributes USDC the contract already holds to a post id.
    /// @dev Operator only. Moves no funds: it records who paid for the post and how much of the
    ///      held balance belongs to it. The deposit must have landed first, because the total
    ///      attributed, with the revenue owed, can never exceed the contract's USDC balance.
    /// @param postId The server's id for the pay-to-special post.
    /// @param payer The address the asker paid from; the refund destination.
    /// @param amount The USDC amount to attribute, in 6-decimal base units.
    function credit(bytes32 postId, address payer, uint96 amount) external onlyOperator {
        if (posts[postId].status != Status.None) revert PostAlreadyCredited();
        if (payer == address(0)) revert ZeroAddress();
        if (payer == address(this)) revert EscrowIsParty();
        if (amount == 0) revert ZeroAmount();

        uint256 credited = totalCredited + amount;
        if (credited + revenueOwed > usdc.balanceOf(address(this))) revert AmountExceedsBalance();

        uint64 fundedAt = uint64(block.timestamp);
        posts[postId] = Post({payer: payer, amount: amount, status: Status.Funded, fundedAt: fundedAt});
        totalCredited = credited;

        emit Credited(postId, payer, amount, fundedAt);
    }

    /// @notice Pays out a funded post: 90% to the winning answer, the remainder kept as revenue.
    /// @dev Operator only. Pays the winner share and adds the rest to `revenueOwed`. The winner
    ///      share rounds down, so the two always sum to exactly the credited amount.
    /// @param postId The post id to release.
    /// @param winner The address of the answer the asker chose.
    function release(bytes32 postId, address winner) external onlyOperator {
        Post storage post = posts[postId];
        if (post.status != Status.Funded) revert PostNotFunded();
        if (winner == address(0)) revert ZeroAddress();
        if (winner == address(this)) revert EscrowIsParty();
        if (winner == post.payer) revert WinnerIsPayer();

        uint256 amount = post.amount;
        post.status = Status.Released;
        totalCredited -= amount;

        uint256 winnerAmount = (amount * RECIPIENT_BPS) / BPS;
        uint256 revenueAmount = amount - winnerAmount;
        revenueOwed += revenueAmount;

        emit Released(postId, winner, winnerAmount, revenueAmount);

        usdc.safeTransfer(winner, winnerAmount);
    }

    /// @notice Takes a funded post off the board once the refund delay has passed: 90% back to the
    ///         asker who paid it, the remainder kept as revenue.
    /// @dev Anyone may call this, because the money can only go to the payer the credit recorded
    ///      and the deadline is the contract's own. A post whose answer was already released is not
    ///      funded any more, so it cannot be refunded. The payer share rounds down, so the two
    ///      always sum to exactly the credited amount.
    /// @param postId The post id to refund.
    function refund(bytes32 postId) external {
        Post storage post = posts[postId];
        if (post.status != Status.Funded) revert PostNotFunded();
        if (block.timestamp < post.fundedAt + REFUND_DELAY) revert RefundTooEarly();

        address payer = post.payer;
        uint256 amount = post.amount;
        post.status = Status.Refunded;
        totalCredited -= amount;

        uint256 payerAmount = (amount * RECIPIENT_BPS) / BPS;
        uint256 revenueAmount = amount - payerAmount;
        revenueOwed += revenueAmount;

        emit Refunded(postId, payer, payerAmount, revenueAmount);

        usdc.safeTransfer(payer, payerAmount);
    }

    /// @notice Deposits all the revenue owed into the REGENT revenue staking contract, tagged
    ///         `patchbay.escrow`.
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

    /// @dev Sets the operator and emits `OperatorChanged`. Used by the constructor and by
    ///      `setOperator`; rejects the zero address so the escrow always has a live operator.
    /// @param newOperator The new operator address.
    function _setOperator(address newOperator) private {
        if (newOperator == address(0)) revert ZeroAddress();

        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }
}
