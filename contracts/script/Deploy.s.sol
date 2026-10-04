// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PatchbayEscrow, IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

/// @title Deploy
/// @notice Deploys PatchbayEscrow. Reads USDC (defaulting to Base mainnet USDC), STAKING,
///         OPERATOR and OWNER from the environment and prints the deployed address.
contract Deploy is Script {
    /// @notice Circle's native USDC on Base mainnet.
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Deploys the escrow with the configured token, staking contract, operator and owner.
    /// @return escrow The deployed escrow.
    function run() external returns (PatchbayEscrow escrow) {
        address usdc = vm.envOr("USDC", BASE_USDC);
        address staking = vm.envAddress("STAKING");
        address operator = vm.envAddress("OPERATOR");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        escrow = new PatchbayEscrow(IERC20(usdc), IRegentRevenueStaking(staking), operator, owner);
        vm.stopBroadcast();

        console2.log("PatchbayEscrow:", address(escrow));
        console2.log("  usdc:        ", usdc);
        console2.log("  staking:     ", staking);
        console2.log("  operator:    ", operator);
        console2.log("  owner:       ", escrow.owner());
    }
}
