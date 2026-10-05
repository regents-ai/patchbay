// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PatchbayEscrow, IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

/// @notice A six-decimal token standing in for USDC.
contract TestUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stands in for the REGENT revenue staking contract: pulls the deposit, and can be paused.
contract TestStaking is IRegentRevenueStaking {
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

/// @title PatchbayEscrowTest
/// @notice What the escrow promises about money: an attribution can never exceed what is held, a
///         post pays out once, both payouts follow the same 90/10 split, a bounty cannot be
///         taken back before the refund delay has passed, and the 10% reaches the stakers without
///         a paused staking contract ever holding up a payout.
contract PatchbayEscrowTest is Test {
    TestUSDC internal usdc;
    TestStaking internal staking;
    PatchbayEscrow internal escrow;

    address internal operator = makeAddr("operator");
    address internal owner = makeAddr("owner");
    address internal payer = makeAddr("payer");
    address internal winner = makeAddr("winner");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant POST = keccak256("post-1");
    uint96 internal constant DEPOSIT = 100_000_000;

    event Credited(bytes32 indexed postId, address indexed payer, uint96 amount, uint64 fundedAt);
    event Refunded(bytes32 indexed postId, address indexed payer, uint256 payerAmount, uint256 revenueAmount);
    event RevenuePushed(address indexed caller, uint256 amount);

    function setUp() public {
        usdc = new TestUSDC();
        staking = new TestStaking(IERC20(address(usdc)));
        escrow = new PatchbayEscrow(IERC20(address(usdc)), staking, operator, owner);
    }

    function test_owner_isTheConstructedAddressAndAloneCanSetOperator() public {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), address(0));
        assertTrue(owner != address(this));

        address nextOperator = makeAddr("next-operator");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.setOperator(nextOperator);

        vm.prank(owner);
        escrow.setOperator(nextOperator);
        assertEq(escrow.operator(), nextOperator);
    }

    /// @dev The x402 settlement lands before the operator attributes it, which is the real order.
    function _fund(bytes32 postId) internal {
        usdc.mint(address(escrow), DEPOSIT);
        vm.prank(operator);
        escrow.credit(postId, payer, DEPOSIT);
    }

    function test_credit_recordsThePayerAndTheMoment() public {
        usdc.mint(address(escrow), DEPOSIT);

        vm.expectEmit(true, true, false, true);
        emit Credited(POST, payer, DEPOSIT, uint64(block.timestamp));
        vm.prank(operator);
        escrow.credit(POST, payer, DEPOSIT);

        (address recordedPayer, uint96 amount, PatchbayEscrow.Status status, uint64 fundedAt) = escrow.posts(POST);
        assertEq(recordedPayer, payer);
        assertEq(amount, DEPOSIT);
        assertEq(uint8(status), uint8(PatchbayEscrow.Status.Funded));
        assertEq(fundedAt, uint64(block.timestamp));
        assertEq(escrow.totalCredited(), DEPOSIT);
    }

    function test_credit_cannotAttributeMoreThanIsHeld() public {
        usdc.mint(address(escrow), DEPOSIT);
        vm.startPrank(operator);
        escrow.credit(POST, payer, DEPOSIT);

        vm.expectRevert(PatchbayEscrow.AmountExceedsBalance.selector);
        escrow.credit(keccak256("post-2"), payer, 1);
        vm.stopPrank();
    }

    function test_credit_cannotAttributeTheRevenueOwed() public {
        _fund(POST);
        vm.startPrank(operator);
        escrow.release(POST, winner);

        // The escrow still holds the 10% it owes the stakers; none of it can become a bounty.
        vm.expectRevert(PatchbayEscrow.AmountExceedsBalance.selector);
        escrow.credit(keccak256("post-2"), payer, 1);
        vm.stopPrank();
    }

    /// @dev A payout to itself would leave the money in the escrow, marked paid but owned by no post.
    function test_theEscrowCannotBeThePayerOrTheWinner() public {
        usdc.mint(address(escrow), DEPOSIT);
        vm.startPrank(operator);
        vm.expectRevert(PatchbayEscrow.EscrowIsParty.selector);
        escrow.credit(POST, address(escrow), DEPOSIT);

        escrow.credit(POST, payer, DEPOSIT);
        vm.expectRevert(PatchbayEscrow.EscrowIsParty.selector);
        escrow.release(POST, address(escrow));
        vm.stopPrank();
    }

    function test_credit_isOperatorOnly() public {
        usdc.mint(address(escrow), DEPOSIT);
        vm.expectRevert(PatchbayEscrow.NotOperator.selector);
        vm.prank(stranger);
        escrow.credit(POST, payer, DEPOSIT);
    }

    function test_release_paysNinetyTenAndClearsTheCredit() public {
        _fund(POST);

        vm.prank(operator);
        escrow.release(POST, winner);

        assertEq(usdc.balanceOf(winner), 90_000_000);
        assertEq(escrow.revenueOwed(), 10_000_000);
        assertEq(usdc.balanceOf(address(escrow)), 10_000_000);
        assertEq(escrow.totalCredited(), 0);
    }

    function test_release_happensOnce() public {
        _fund(POST);
        vm.startPrank(operator);
        escrow.release(POST, winner);

        vm.expectRevert(PatchbayEscrow.PostNotFunded.selector);
        escrow.release(POST, winner);
        vm.stopPrank();
    }

    function test_refund_isRefusedBeforeTheDelay() public {
        _fund(POST);

        vm.expectRevert(PatchbayEscrow.RefundTooEarly.selector);
        escrow.refund(POST);

        // One second short is still short: this is what stops a refund being the cheap way out of
        // a bounty an asker never intended to pay.
        vm.warp(block.timestamp + escrow.REFUND_DELAY() - 1);
        vm.expectRevert(PatchbayEscrow.RefundTooEarly.selector);
        escrow.refund(POST);

        assertEq(usdc.balanceOf(payer), 0);
        assertEq(escrow.totalCredited(), DEPOSIT);
    }

    function test_refund_afterTheDelayPaysNinetyTenToAnyCaller() public {
        _fund(POST);
        vm.warp(block.timestamp + escrow.REFUND_DELAY());

        vm.expectEmit(true, true, false, true);
        emit Refunded(POST, payer, 90_000_000, 10_000_000);
        // Nobody in particular: the money can only go to the recorded payer, so the asker never
        // waits on Patchbay being up.
        vm.prank(stranger);
        escrow.refund(POST);

        assertEq(usdc.balanceOf(payer), 90_000_000);
        assertEq(escrow.revenueOwed(), 10_000_000);
        assertEq(usdc.balanceOf(address(escrow)), 10_000_000);
        assertEq(escrow.totalCredited(), 0);
    }

    function test_refund_happensOnceAndNotAfterARelease() public {
        _fund(POST);
        vm.warp(block.timestamp + escrow.REFUND_DELAY());
        escrow.refund(POST);

        vm.expectRevert(PatchbayEscrow.PostNotFunded.selector);
        escrow.refund(POST);

        bytes32 released = keccak256("post-2");
        _fund(released);
        vm.prank(operator);
        escrow.release(released, winner);

        vm.warp(block.timestamp + escrow.REFUND_DELAY());
        vm.expectRevert(PatchbayEscrow.PostNotFunded.selector);
        escrow.refund(released);
    }

    function test_release_afterARefundIsRefused() public {
        _fund(POST);
        vm.warp(block.timestamp + escrow.REFUND_DELAY());
        escrow.refund(POST);

        vm.expectRevert(PatchbayEscrow.PostNotFunded.selector);
        vm.prank(operator);
        escrow.release(POST, winner);
    }

    function test_pushRevenue_depositsAllThatIsOwedTaggedForAnyCaller() public {
        _fund(POST);
        vm.prank(operator);
        escrow.release(POST, winner);

        vm.expectEmit(true, false, false, true);
        emit RevenuePushed(stranger, 10_000_000);
        vm.prank(stranger);
        assertEq(escrow.pushRevenue(), 10_000_000);

        assertEq(usdc.balanceOf(address(staking)), 10_000_000);
        assertEq(staking.lastSourceTag(), bytes32("patchbay.escrow"));
        assertEq(escrow.revenueOwed(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        vm.expectRevert(PatchbayEscrow.NothingOwed.selector);
        escrow.pushRevenue();
    }

    /// @dev Sean's 43 a: payouts and refunds never depend on the staking contract being unpaused.
    function test_aPausedStakingContractHoldsUpOnlyThePush() public {
        staking.setPaused(true);
        bytes32 refunded = keccak256("post-2");
        _fund(POST);
        _fund(refunded);

        vm.prank(operator);
        escrow.release(POST, winner);
        vm.warp(block.timestamp + escrow.REFUND_DELAY());
        escrow.refund(refunded);
        assertEq(usdc.balanceOf(winner), 90_000_000);
        assertEq(usdc.balanceOf(payer), 90_000_000);

        vm.expectRevert(bytes("PAUSED"));
        escrow.pushRevenue();
        assertEq(escrow.revenueOwed(), 20_000_000);

        staking.setPaused(false);
        escrow.pushRevenue();
        assertEq(usdc.balanceOf(address(staking)), 20_000_000);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @dev Whatever the amount, the payer share and the revenue sum to it exactly and the
    ///      stakers are never short-changed by rounding.
    function testFuzz_refund_splitsWithoutLosingADrop(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        usdc.mint(address(escrow), amount);
        vm.prank(operator);
        escrow.credit(POST, payer, amount);

        vm.warp(block.timestamp + escrow.REFUND_DELAY());
        escrow.refund(POST);

        assertEq(usdc.balanceOf(payer) + escrow.revenueOwed(), amount);
        assertEq(usdc.balanceOf(payer), (uint256(amount) * escrow.RECIPIENT_BPS()) / escrow.BPS());
        assertEq(usdc.balanceOf(address(escrow)), escrow.revenueOwed());
    }
}
