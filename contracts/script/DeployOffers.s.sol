// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {AgentOfferStakingPayout} from "../src/AgentOfferStakingPayout.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

/// @title DeployOffers
/// @notice Deploys the agent offer contracts on Base mainnet in the README's deploy order: the
///         factory admitting Patchbay's publisher, Patchbay's staking payout contract for the
///         market the factory predicts, then Patchbay's market naming that contract as its payout.
///         Reads OFFERS_ADMIN, OFFERS_OPERATOR, OFFERS_PUBLISHER, OFFERS_STAKING and OFFERS_FEE_BPS
///         from the environment and logs every address.
/// @dev Every transaction is sent from the publisher, because `createMarket` must come from it;
///      the factory and the payout contract give whoever deploys them no role. The publisher's key
///      is handed to `forge script` when it runs and never appears here.
contract DeployOffers is Script {
    /// @notice Deploys with the settings in the environment.
    function run()
        external
        returns (AgentOfferFactory factory, AgentOfferStakingPayout payout, AgentOfferMarket market)
    {
        return deploy(
            vm.envAddress("OFFERS_ADMIN"),
            vm.envAddress("OFFERS_OPERATOR"),
            vm.envAddress("OFFERS_PUBLISHER"),
            IRegentRevenueStaking(vm.envAddress("OFFERS_STAKING")),
            SafeCast.toUint16(vm.envUint("OFFERS_FEE_BPS"))
        );
    }

    /// @notice The README's deploy order, one transaction each, all sent from `publisher`.
    /// @param admin The factory's owner (the Safe), who admits and removes publishers, sets the
    ///        operator and may send to staking.
    /// @param operator The one address besides the owner that may send to staking.
    /// @param publisher Patchbay's publisher address, admitted from the start and the market's publisher.
    /// @param staking The REGENT revenue staking contract the fee and Patchbay's earnings go into.
    /// @param feeBps The protocol fee in basis points; the factory refuses one above the market's maximum.
    function deploy(address admin, address operator, address publisher, IRegentRevenueStaking staking, uint16 feeBps)
        public
        returns (AgentOfferFactory factory, AgentOfferStakingPayout payout, AgentOfferMarket market)
    {
        require(block.chainid == 8453, "DeployOffers: Base mainnet (chain 8453) only");
        require(admin != address(0), "DeployOffers: OFFERS_ADMIN is the zero address");
        require(operator != address(0), "DeployOffers: OFFERS_OPERATOR is the zero address");
        require(publisher != address(0), "DeployOffers: OFFERS_PUBLISHER is the zero address");
        require(address(staking) != address(0), "DeployOffers: OFFERS_STAKING is the zero address");

        vm.startBroadcast(publisher);
        // 1. The factory, with its operator, admitting Patchbay's publisher.
        factory = new AgentOfferFactory(admin, operator, publisher, staking, feeBps);
        // 2. The address Patchbay's market will have.
        address predicted = factory.predictMarket(publisher);
        // 3. The staking payout contract for that market, with the factory's staking contract.
        payout = new AgentOfferStakingPayout(factory, publisher);
        require(
            address(payout.market()) == predicted && address(payout.staking()) == address(factory.staking()),
            "DeployOffers: the payout contract does not serve the predicted market"
        );
        // 4. Patchbay's market, from the publisher, naming the payout contract.
        market = AgentOfferMarket(factory.createMarket(address(payout)));
        vm.stopBroadcast();

        // 5. The market is the factory's for the publisher, and it pays the payout contract.
        require(
            factory.marketOf(publisher) == address(payout.market()) && market.payout() == address(payout),
            "DeployOffers: the market does not pay the payout contract"
        );

        console2.log("AgentOfferFactory:      ", address(factory));
        console2.log("  implementation:       ", factory.implementation());
        console2.log("  owner:                ", factory.owner());
        console2.log("  operator:             ", factory.operator());
        console2.log("  staking:              ", address(factory.staking()));
        console2.log("  fee (bps):            ", uint256(factory.feeBps()));
        console2.log("AgentOfferStakingPayout:", address(payout));
        console2.log("AgentOfferMarket:       ", address(market));
        console2.log("  publisher:            ", market.publisher());
        console2.log("  payout:               ", market.payout());
    }
}
