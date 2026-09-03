// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title PatchbayEscrow
/// @notice Holds the USDC a Patchbay asker pays for a pay-to-special forum post until the asker
///         picks a correct answer, then pays the winner 90% and the Patchbay treasury 10%.
/// @dev The asker pays over x402, whose settlement is a plain USDC transfer to this contract, so a
///      deposit arrives with no indication of which post it belongs to. The Patchbay server (the
///      operator) attributes each confirmed deposit to a post id with `credit`, and later calls
///      `release` or `refund`. The contract is an operator-trusted ledger with an immutable split:
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
    struct Post {
        address payer;
        uint96 amount;
        Status status;
    }

    /// @notice Share of a released amount paid to the winning answer, in basis points.
    uint256 public constant WINNER_BPS = 9000;

    /// @notice Share of a released amount paid to the treasury, in basis points.
    uint256 public constant TREASURY_BPS = 1000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The USDC token this escrow holds and pays out.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usdc;

    /// @notice The Regents splitter contract that receives the treasury share of every release.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable treasury;

    /// @notice The Patchbay server address allowed to credit, release and refund.
    address public operator;

    /// @notice Attributed deposits, keyed by the post id the server assigns.
    mapping(bytes32 postId => Post) public posts;

    /// @notice Sum of the amounts of all posts currently in `Funded` status.
    /// @dev USDC held beyond this figure is unattributed: deposits that have arrived but have not
    ///      been credited yet. It stays in the contract until the operator credits it.
    uint256 public totalCredited;

    /// @notice Emitted when the owner changes the operator, and once at deployment.
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    /// @notice Emitted when the operator attributes a deposit to a post id.
    event Credited(bytes32 indexed postId, address indexed payer, uint96 amount);

    /// @notice Emitted when the operator releases a funded post to a winning answer.
    event Released(bytes32 indexed postId, address indexed winner, uint256 winnerAmount, uint256 treasuryAmount);

    /// @notice Emitted when the operator refunds a funded post to its payer.
    event Refunded(bytes32 indexed postId, address indexed payer, uint96 amount);

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

    /// @dev Restricts a call to the Patchbay server. One check, three call sites; kept inline so
    ///      the access rule is readable at the point it is enforced.
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Deploys the escrow. The deployer becomes the owner and should hand ownership to a
    ///         safe address with `transferOwnership` / `acceptOwnership`.
    /// @param usdc_ The USDC token address on this chain.
    /// @param treasury_ The Regents splitter contract that receives the 10% treasury share.
    /// @param operator_ The Patchbay server address allowed to credit, release and refund.
    constructor(IERC20 usdc_, address treasury_, address operator_) Ownable(msg.sender) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        usdc = usdc_;
        treasury = treasury_;
        _setOperator(operator_);
    }

    /// @notice Points the escrow at a new Patchbay server address.
    /// @dev Owner only. Moves no funds; it only changes who may call credit, release and refund.
    /// @param newOperator The new operator address.
    function setOperator(address newOperator) external onlyOwner {
        _setOperator(newOperator);
    }

    /// @notice Attributes USDC the contract already holds to a post id.
    /// @dev Operator only. Moves no funds: it records who paid for the post and how much of the
    ///      held balance belongs to it. The deposit must have landed first, because the total
    ///      attributed can never exceed the contract's USDC balance.
    /// @param postId The server's id for the pay-to-special post.
    /// @param payer The address the asker paid from; the refund destination.
    /// @param amount The USDC amount to attribute, in 6-decimal base units.
    function credit(bytes32 postId, address payer, uint96 amount) external onlyOperator {
        if (posts[postId].status != Status.None) revert PostAlreadyCredited();
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 credited = totalCredited + amount;
        if (credited > usdc.balanceOf(address(this))) revert AmountExceedsBalance();

        posts[postId] = Post({payer: payer, amount: amount, status: Status.Funded});
        totalCredited = credited;

        emit Credited(postId, payer, amount);
    }

    /// @notice Pays out a funded post: 90% to the winning answer, the remainder to the treasury.
    /// @dev Operator only. Moves the post's full amount out of the contract, split between
    ///      `winner` and the immutable treasury address. The winner share rounds down, so the two
    ///      transfers always sum to exactly the credited amount.
    /// @param postId The post id to release.
    /// @param winner The address of the answer the asker chose.
    function release(bytes32 postId, address winner) external onlyOperator {
        Post storage post = posts[postId];
        if (post.status != Status.Funded) revert PostNotFunded();
        if (winner == address(0)) revert ZeroAddress();
        if (winner == post.payer) revert WinnerIsPayer();

        uint256 amount = post.amount;
        post.status = Status.Released;
        totalCredited -= amount;

        uint256 winnerAmount = (amount * WINNER_BPS) / BPS;
        uint256 treasuryAmount = amount - winnerAmount;

        emit Released(postId, winner, winnerAmount, treasuryAmount);

        usdc.safeTransfer(winner, winnerAmount);
        usdc.safeTransfer(treasury, treasuryAmount);
    }

    /// @notice Returns a funded post's full amount to the asker who paid it.
    /// @dev Operator only. Moves the post's full amount out of the contract to its payer, with no
    ///      split and no fee.
    /// @param postId The post id to refund.
    function refund(bytes32 postId) external onlyOperator {
        Post storage post = posts[postId];
        if (post.status != Status.Funded) revert PostNotFunded();

        address payer = post.payer;
        uint96 amount = post.amount;
        post.status = Status.Refunded;
        totalCredited -= amount;

        emit Refunded(postId, payer, amount);

        usdc.safeTransfer(payer, amount);
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
