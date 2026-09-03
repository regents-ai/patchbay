// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PatchbayEscrow} from "../src/PatchbayEscrow.sol";

/// @title Deploy
/// @notice Deploys PatchbayEscrow. Reads USDC (defaulting to Base mainnet USDC), TREASURY and
///         OPERATOR from the environment and prints the deployed address.
contract Deploy is Script {
    /// @notice Circle's native USDC on Base mainnet.
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Deploys the escrow with the configured token, treasury and operator.
    /// @return escrow The deployed escrow.
    function run() external returns (PatchbayEscrow escrow) {
        address usdc = vm.envOr("USDC", BASE_USDC);
        address treasury = vm.envAddress("TREASURY");
        address operator = vm.envAddress("OPERATOR");

        vm.startBroadcast();
        escrow = new PatchbayEscrow(IERC20(usdc), treasury, operator);
        vm.stopBroadcast();

        console2.log("PatchbayEscrow:", address(escrow));
        console2.log("  usdc:        ", usdc);
        console2.log("  treasury:    ", treasury);
        console2.log("  operator:    ", operator);
        console2.log("  owner:       ", escrow.owner());
    }
}
