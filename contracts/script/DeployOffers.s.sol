// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {PatchbayOffersEscrow} from "../src/PatchbayOffersEscrow.sol";

/// @title DeployOffers
/// @notice Deploys PatchbayOffersEscrow on Base mainnet. Consumed and forfeited USDC goes to the
///         REGENT revenue staking contract, which is fixed here (Sean, 5 Oct 2026, HQ 98 decision 2 a).
///         Reads OPERATOR and OWNER from the environment and prints the deployed address.
contract DeployOffers is Script {
    /// @notice Circle's native USDC on Base mainnet.
    IERC20 internal constant BASE_USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice The REGENT revenue staking contract on Base mainnet.
    IRegentRevenueStaking internal constant STAKING = IRegentRevenueStaking(0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5);

    /// @notice Deploys the escrow with the configured operator and owner.
    /// @return escrow The deployed escrow.
    function run() external returns (PatchbayOffersEscrow escrow) {
        address operator = vm.envAddress("OPERATOR");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        escrow = new PatchbayOffersEscrow(BASE_USDC, STAKING, operator, owner);
        vm.stopBroadcast();

        console2.log("PatchbayOffersEscrow:", address(escrow));
        console2.log("  usdc:    ", address(BASE_USDC));
        console2.log("  staking: ", address(STAKING));
        console2.log("  operator:", operator);
        console2.log("  owner:   ", escrow.owner());
    }
}
