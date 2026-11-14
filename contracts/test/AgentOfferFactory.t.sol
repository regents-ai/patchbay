// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {IAgentOfferMarket} from "../src/IAgentOfferMarket.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {AgentOfferBase, FreezableUSDC} from "./AgentOfferTestKit.sol";

/// @title AgentOfferFactoryTest
/// @notice What the factory promises: it deploys only on Base with Circle's USDC there, a staking
///         contract with code and a fee no higher than a fifth; it admits Patchbay from the start and
///         others only by the owner; each admitted publisher gets exactly one market, at the address
///         `predictMarket` gave beforehand, set up in the same call and never again; and an
///         admission signed for one market is worthless on any other.
contract AgentOfferFactoryTest is AgentOfferBase {
    address internal other = makeAddr("other-publisher");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deploy(new FreezableUSDC());
    }

    // ---------------------------------------------------------------- deployment

    function test_constructor_pinsBaseUsdcAndAdmitsPatchbay() public {
        assertEq(factory.BASE_USDC(), BASE_USDC);
        assertEq(factory.owner(), admin);
        assertEq(address(factory.staking()), address(staking));
        assertEq(factory.feeBps(), FEE_BPS);
        assertTrue(factory.publisherAllowed(publisher));
        assertFalse(factory.publisherAllowed(other));
        assertGt(factory.implementation().code.length, 0);

        vm.expectEmit();
        emit AgentOfferFactory.PublisherAllowed(other, true);
        new AgentOfferFactory(admin, other, staking, 2_000);
        new AgentOfferFactory(admin, other, staking, 0);
    }

    function test_constructor_refusesAnythingButBaseWithItsUsdc() public {
        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        new AgentOfferFactory(admin, address(0), staking, FEE_BPS);

        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        new AgentOfferFactory(admin, publisher, IRegentRevenueStaking(address(0)), FEE_BPS);

        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        new AgentOfferFactory(admin, publisher, IRegentRevenueStaking(stranger), FEE_BPS);

        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        new AgentOfferFactory(admin, publisher, staking, 2_001);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AgentOfferFactory(address(0), publisher, staking, FEE_BPS);

        // Base Sepolia, and any other chain, is refused.
        vm.chainId(84532);
        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        new AgentOfferFactory(admin, publisher, staking, FEE_BPS);

        vm.chainId(8453);
        vm.etch(BASE_USDC, "");
        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        new AgentOfferFactory(admin, publisher, staking, FEE_BPS);
    }

    function test_implementation_cannotBeInitialized() public {
        AgentOfferMarket implementation = AgentOfferMarket(factory.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            IAgentOfferMarket.Init({usdc: usdc, publisher: stranger, payout: stranger, staking: staking, feeBps: 0})
        );
    }

    // ---------------------------------------------------------------- publishers

    function test_setPublisherAllowed_isOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, publisher));
        vm.prank(publisher);
        factory.setPublisherAllowed(other, true);

        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        vm.prank(admin);
        factory.setPublisherAllowed(address(0), true);

        vm.expectEmit(address(factory));
        emit AgentOfferFactory.PublisherAllowed(other, true);
        vm.prank(admin);
        factory.setPublisherAllowed(other, true);
        assertTrue(factory.publisherAllowed(other));
    }

    function test_ownership_handsOverInTwoSteps() public {
        vm.prank(admin);
        factory.transferOwnership(other);
        assertEq(factory.owner(), admin);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.acceptOwnership();

        vm.prank(other);
        factory.acceptOwnership();
        assertEq(factory.owner(), other);
    }

    // ---------------------------------------------------------------- markets

    function test_createMarket_atThePredictedAddressSetUpInTheSameCall() public {
        vm.prank(admin);
        factory.setPublisherAllowed(other, true);
        address predicted = factory.predictMarket(other);
        assertEq(predicted.code.length, 0);
        address otherPayout = makeAddr("other-payout");

        vm.expectEmit(address(factory));
        emit AgentOfferFactory.MarketCreated(other, predicted, otherPayout);
        vm.expectEmit(predicted);
        emit IAgentOfferMarket.MarketInitialized(other, otherPayout, BASE_USDC, address(staking), FEE_BPS);
        vm.prank(other);
        AgentOfferMarket created = AgentOfferMarket(factory.createMarket(otherPayout));

        assertEq(address(created), predicted);
        assertEq(factory.marketOf(other), predicted);
        assertEq(address(created.usdc()), BASE_USDC);
        assertEq(created.publisher(), other);
        assertEq(created.payout(), otherPayout);
        assertEq(address(created.staking()), address(staking));
        assertEq(created.feeBps(), FEE_BPS);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        created.initialize(
            IAgentOfferMarket.Init({usdc: usdc, publisher: stranger, payout: stranger, staking: staking, feeBps: 0})
        );
    }

    function test_createMarket_addressDoesNotDependOnOrder() public {
        vm.startPrank(admin);
        factory.setPublisherAllowed(other, true);
        factory.setPublisherAllowed(stranger, true);
        vm.stopPrank();
        address predictedOther = factory.predictMarket(other);
        address predictedStranger = factory.predictMarket(stranger);
        assertTrue(predictedOther != predictedStranger);

        vm.prank(stranger);
        assertEq(factory.createMarket(payout), predictedStranger);
        vm.prank(other);
        assertEq(factory.createMarket(payout), predictedOther);
        assertEq(factory.predictMarket(publisher), address(market));
    }

    function test_createMarket_onceEachAndOnlyForAdmittedPublishers() public {
        vm.expectRevert(AgentOfferFactory.PublisherNotAllowed.selector);
        vm.prank(other);
        factory.createMarket(payout);

        vm.expectRevert(AgentOfferFactory.MarketAlreadyExists.selector);
        vm.prank(publisher);
        factory.createMarket(payout);

        vm.prank(admin);
        factory.setPublisherAllowed(other, true);
        address itsOwnMarket = factory.predictMarket(other);
        vm.startPrank(other);
        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        factory.createMarket(address(0));
        vm.expectRevert(AgentOfferFactory.InvalidConfiguration.selector);
        factory.createMarket(itsOwnMarket);
        vm.stopPrank();
    }

    function test_removingAPublisherLeavesItsMarketRunning() public {
        uint256 id = _patchbayPlacement(market);
        _buy(market, makeAddr("alice"), id, 0, FLOOR);

        vm.prank(admin);
        factory.setPublisherAllowed(publisher, false);
        assertFalse(factory.publisherAllowed(publisher));

        skip(1 hours);
        _buy(market, makeAddr("bob"), id, 0, 5_500_000);
        vm.prank(makeAddr("alice"));
        assertGt(market.claim(makeAddr("alice")), 0);
        _assertBooks(market);
    }

    function test_aZeroFeeMarketKeepsNothingForStaking() public {
        AgentOfferFactory free = new AgentOfferFactory(admin, publisher, staking, 0);
        vm.prank(publisher);
        AgentOfferMarket freeMarket = AgentOfferMarket(free.createMarket(payout));
        uint256 id = _patchbayPlacement(freeMarket);

        _buy(freeMarket, makeAddr("alice"), id, 0, FLOOR);
        skip(DURATION);
        freeMarket.settleExpired(id, 0);
        assertEq(freeMarket.claimable(payout), FLOOR);
        assertEq(freeMarket.revenueOwed(), 0);
        vm.expectRevert(IAgentOfferMarket.NothingOwed.selector);
        freeMarket.pushRevenue();
    }

    // ---------------------------------------------------------------- EIP-712 under clones

    /// @dev Two markets with the same publisher key, the same placement id, slot, nonce, source,
    ///      policy and price: only the market's own address differs, and the admission signed for
    ///      market A is refused by market B. The implementation's cached domain is never used.
    function test_aPermitForMarketAIsRefusedByMarketB() public {
        AgentOfferFactory second = new AgentOfferFactory(admin, publisher, staking, FEE_BPS);
        vm.prank(publisher);
        AgentOfferMarket marketB = AgentOfferMarket(second.createMarket(payout));
        assertTrue(address(marketB) != address(market));

        uint256 idA = _patchbayPlacement(market);
        uint256 idB = _patchbayPlacement(marketB);
        assertEq(idA, idB);

        address alice = makeAddr("alice");
        IAgentOfferMarket.Purchase memory p = _purchase(market, alice, idA, 0, FLOOR);
        bytes memory permitForA = _permit(market, p, alice);
        assertTrue(market.eligibilityDigest(p, alice) != marketB.eligibilityDigest(p, alice));

        (,,, uint256 chainA, address verifyingA,,) = market.eip712Domain();
        (,,, uint256 chainB, address verifyingB,,) = marketB.eip712Domain();
        (,,,, address verifyingImpl,,) = AgentOfferMarket(factory.implementation()).eip712Domain();
        assertEq(verifyingA, address(market));
        assertEq(verifyingB, address(marketB));
        assertEq(verifyingImpl, factory.implementation());
        assertEq(chainA, 8453);
        assertEq(chainB, 8453);

        _fund(marketB, alice, FLOOR);
        vm.expectRevert(IAgentOfferMarket.InvalidPermit.selector);
        vm.prank(alice);
        marketB.buy(p, permitForA);

        _fund(market, alice, FLOOR);
        vm.prank(alice);
        market.buy(p, permitForA);
        assertEq(market.getLease(idA, 0).buyer, alice);
        assertEq(marketB.getLease(idB, 0).buyer, address(0));
    }
}
