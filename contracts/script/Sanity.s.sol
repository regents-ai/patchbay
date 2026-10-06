// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PatchbayEscrow, IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

/// @title Sanity
/// @notice Walks one deposit through credit -> release and a second through credit -> wait -> refund
///         against real Base mainnet USDC on a local fork, then pushes the 10% kept from both into
///         the real REGENT revenue staking contract. Simulation only; never broadcast.
/// @dev Run with: forge script script/Sanity.s.sol --rpc-url $BASE_RPC_URL
contract Sanity is Script, StdCheats {
    /// @notice Circle's native USDC on Base mainnet.
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice The REGENT revenue staking contract on Base mainnet.
    IRegentRevenueStaking internal constant STAKING = IRegentRevenueStaking(0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5);

    /// @notice 100 USDC, in 6-decimal base units.
    uint96 internal constant DEPOSIT = 100_000_000;

    /// @notice Deploys the escrow on the fork and checks both payout paths and the push.
    function run() external {
        address operator = makeAddr("operator");
        address owner = makeAddr("owner");
        address payer = makeAddr("payer");
        address winner = makeAddr("winner");

        PatchbayEscrow escrow = new PatchbayEscrow(USDC, STAKING, operator, owner);
        console2.log("escrow:", address(escrow));
        vm.startPrank(operator);

        // Release path: the x402 settlement lands first, then the operator attributes it.
        deal(address(USDC), address(escrow), DEPOSIT);
        escrow.credit(keccak256("post-1"), payer, DEPOSIT);
        require(escrow.totalCredited() == DEPOSIT, "credit did not record the deposit");

        escrow.release(keccak256("post-1"), winner);
        require(USDC.balanceOf(winner) == 90_000_000, "winner did not receive 90%");
        require(escrow.revenueOwed() == 10_000_000, "release did not keep 10%");
        require(escrow.totalCredited() == 0, "release did not clear the credit");
        console2.log("release ok: winner", USDC.balanceOf(winner), "revenue owed", escrow.revenueOwed());

        // Refund path: funded now, refundable only once the delay has passed, and refundable by
        // somebody who is not the operator.
        // `deal` sets a balance, so the 10% the escrow still owes is kept in it.
        deal(address(USDC), address(escrow), USDC.balanceOf(address(escrow)) + DEPOSIT);
        escrow.credit(keccak256("post-2"), payer, DEPOSIT);
        vm.stopPrank();

        vm.warp(block.timestamp + escrow.REFUND_DELAY());
        vm.prank(makeAddr("a passer-by"));
        escrow.refund(keccak256("post-2"));
        require(USDC.balanceOf(payer) == 90_000_000, "payer did not receive 90%");
        require(escrow.revenueOwed() == 20_000_000, "refund did not keep 10%");
        require(escrow.totalCredited() == 0, "refund did not clear the credit");
        console2.log("refund ok: payer", USDC.balanceOf(payer), "revenue owed", escrow.revenueOwed());

        // Push: anybody may hand what is owed to REGENT staking.
        uint256 stakingBefore = USDC.balanceOf(address(STAKING));
        vm.prank(makeAddr("another passer-by"));
        escrow.pushRevenue();
        require(USDC.balanceOf(address(STAKING)) == stakingBefore + 20_000_000, "staking did not receive 20");
        require(escrow.revenueOwed() == 0, "push did not clear the revenue owed");
        require(USDC.balanceOf(address(escrow)) == 0, "escrow retained funds after the push");
        console2.log("push ok: staking received", USDC.balanceOf(address(STAKING)) - stakingBefore);
    }
}
