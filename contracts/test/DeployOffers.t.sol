// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferStakingPayout} from "../src/AgentOfferStakingPayout.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {DeployOffers} from "../script/DeployOffers.s.sol";
import {AgentOfferBase, FreezableUSDC} from "./AgentOfferTestKit.sol";

/// @title DeployOffersTest
/// @notice `script/DeployOffers.s.sol` on the test kit's Base: it deploys the factory, Patchbay's
///         staking payout contract and Patchbay's market wired as the README's deploy order says,
///         the market it leaves sells and pays everything earned into staking, it reads its
///         settings from the environment, and it refuses another chain and every zero address.
contract DeployOffersTest is AgentOfferBase {
    DeployOffers internal script;
    AgentOfferStakingPayout internal earnings;

    function setUp() public {
        _baseChain(new FreezableUSDC());
        script = new DeployOffers();
    }

    function test_deploy_wiresFactoryPayoutAndMarketAsTheReadmeSays() public {
        (factory, earnings, market) = script.deploy(admin, publisher, staking, FEE_BPS);

        assertEq(factory.owner(), admin);
        assertTrue(factory.publisherAllowed(publisher));
        assertEq(address(factory.staking()), address(staking));
        assertEq(factory.feeBps(), FEE_BPS);
        assertGt(factory.implementation().code.length, 0);

        assertEq(address(market), factory.predictMarket(publisher), "predicted");
        assertEq(factory.marketOf(publisher), address(market));
        assertEq(address(earnings.market()), address(market));
        assertEq(address(earnings.staking()), address(staking));
        assertEq(address(earnings.usdc()), BASE_USDC);

        assertEq(market.publisher(), publisher);
        assertEq(market.payout(), address(earnings));
        assertEq(address(market.usdc()), BASE_USDC);
        assertEq(address(market.staking()), address(staking));
        assertEq(market.feeBps(), FEE_BPS);
    }

    function test_deploy_leavesAMarketThatSellsAndPaysStaking() public {
        (factory, earnings, market) = script.deploy(admin, publisher, staking, FEE_BPS);
        payout = address(earnings);

        uint256 placementId = _patchbayPlacement(market);
        _buy(market, makeAddr("advertiser"), placementId, 0, FLOOR);
        skip(DURATION);
        market.settleExpired(placementId, 0);

        assertEq(market.pushRevenue(), FLOOR / 10, "fee");
        assertEq(staking.lastSourceTag(), market.SOURCE_TAG());
        assertEq(earnings.pushEarnings(), FLOOR - FLOOR / 10, "Patchbay's share");
        assertEq(staking.lastSourceTag(), earnings.SOURCE_TAG());
        assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(market)))));
        assertEq(usdc.balanceOf(address(staking)), FLOOR, "everything earned is in staking");
        _assertBooks(market);
    }

    function test_run_readsItsSettingsFromTheEnvironment() public {
        vm.setEnv("OFFERS_ADMIN", vm.toString(admin));
        vm.setEnv("OFFERS_PUBLISHER", vm.toString(publisher));
        vm.setEnv("OFFERS_STAKING", vm.toString(address(staking)));
        vm.setEnv("OFFERS_FEE_BPS", "1500");

        (factory, earnings, market) = script.run();

        assertEq(factory.owner(), admin);
        assertEq(market.publisher(), publisher);
        assertEq(address(market.staking()), address(staking));
        assertEq(market.feeBps(), 1_500);
        assertEq(market.payout(), address(earnings));
    }

    function test_deploy_refusesAnotherChain() public {
        vm.chainId(84532);
        vm.expectRevert(bytes("DeployOffers: Base mainnet (chain 8453) only"));
        script.deploy(admin, publisher, staking, FEE_BPS);
    }

    function test_deploy_refusesAZeroAddress() public {
        vm.expectRevert(bytes("DeployOffers: OFFERS_ADMIN is the zero address"));
        script.deploy(address(0), publisher, staking, FEE_BPS);

        vm.expectRevert(bytes("DeployOffers: OFFERS_PUBLISHER is the zero address"));
        script.deploy(admin, address(0), staking, FEE_BPS);

        vm.expectRevert(bytes("DeployOffers: OFFERS_STAKING is the zero address"));
        script.deploy(admin, publisher, IRegentRevenueStaking(address(0)), FEE_BPS);
    }

    function test_deploy_leavesTheFeeCapToTheFactory() public {
        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        script.deploy(admin, publisher, staking, 2_001);
    }
}
