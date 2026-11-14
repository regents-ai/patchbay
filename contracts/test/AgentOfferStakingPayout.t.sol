// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {AgentOfferStakingPayout} from "../src/AgentOfferStakingPayout.sol";
import {IAgentOfferMarket} from "../src/IAgentOfferMarket.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {AgentOfferBase, FreezableUSDC} from "./AgentOfferTestKit.sol";

/// @notice Shared set-up: Patchbay's market created with the staking payout contract as its payout
///         address, deployed in the order the README gives.
abstract contract StakingPayoutBase is AgentOfferBase {
    AgentOfferStakingPayout internal earnings;
    uint256 internal placementId;

    /// @dev The payout contract for the factory's Patchbay market, then the market naming it.
    function _deployPayoutAndMarket() internal {
        earnings = new AgentOfferStakingPayout(factory, publisher);
        payout = address(earnings);
        vm.prank(publisher);
        market = AgentOfferMarket(factory.createMarket(payout));
        placementId = _patchbayPlacement(market);
    }

    /// @dev A lease on slot `slot` paying `amount`, run to its end and settled, so the payout
    ///      contract is credited the amount less the 10% fee. Returns that credit.
    function _earn(uint16 slot, uint256 amount) internal returns (uint256 credited) {
        uint256 before = market.claimable(payout);
        _buy(market, makeAddr("advertiser"), placementId, slot, amount);
        skip(DURATION);
        market.settleExpired(placementId, slot);
        credited = market.claimable(payout) - before;
    }

    function _ref() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(market))));
    }
}

/// @title AgentOfferStakingPayoutTest
/// @notice What the staking payout promises: it serves exactly the market its factory creates for
///         its publisher; anyone may push; a push deposits everything the market owes it, and any
///         USDC it holds, into the market's own staking contract tagged `agent.offers.payout`, and
///         leaves nothing behind; and a paused staking contract leaves the earnings owed in the
///         market.
contract AgentOfferStakingPayoutTest is StakingPayoutBase {
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployFactory(new FreezableUSDC());
        _deployPayoutAndMarket();
    }

    // ---------------------------------------------------------------- set-up

    function test_constructor_fixesTheMarketTheFactoryWillCreate() public {
        address later = makeAddr("later-publisher");
        address predicted = factory.predictMarket(later);
        assertEq(predicted.code.length, 0, "no market yet");

        AgentOfferStakingPayout fresh = new AgentOfferStakingPayout(factory, later);
        assertEq(address(fresh.market()), predicted);
        assertEq(address(fresh.usdc()), BASE_USDC);
        assertEq(address(fresh.staking()), address(factory.staking()));

        vm.prank(admin);
        factory.setPublisherAllowed(later, true);
        vm.prank(later);
        AgentOfferMarket created = AgentOfferMarket(factory.createMarket(address(fresh)));
        assertEq(address(created), address(fresh.market()));
        assertEq(created.payout(), address(fresh));
    }

    function test_patchbayMarketPaysThisContractAndPushesItsFeeToTheSameStaking() public view {
        assertEq(address(earnings.market()), factory.marketOf(publisher));
        assertEq(market.payout(), address(earnings));
        assertEq(address(earnings.staking()), address(market.staking()));
        assertEq(address(earnings.usdc()), address(market.usdc()));
        assertTrue(earnings.SOURCE_TAG() != market.SOURCE_TAG(), "tags tell the share from the fee");
    }

    function test_constructor_refusesAZeroPublisher() public {
        vm.expectRevert(AgentOfferStakingPayout.InvalidConfiguration.selector);
        new AgentOfferStakingPayout(factory, address(0));
    }

    // ---------------------------------------------------------------- pushes

    function test_pushEarnings_depositsEverythingOwedTaggedForAnyCaller() public {
        assertEq(_earn(0, 6_000_000), 5_400_000);

        vm.expectEmit(address(earnings));
        emit AgentOfferStakingPayout.EarningsPushed(stranger, 5_400_000, 5_400_000);
        vm.prank(stranger);
        assertEq(earnings.pushEarnings(), 5_400_000);

        assertEq(usdc.balanceOf(address(staking)), 5_400_000);
        assertEq(staking.lastSourceTag(), bytes32("agent.offers.payout"));
        assertEq(staking.lastSourceRef(), _ref());
        assertEq(market.claimable(address(earnings)), 0);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        assertEq(usdc.allowance(address(earnings), address(staking)), 0);

        // The fee goes in on its own push, under its own tag; together they are all that was earned.
        vm.prank(stranger);
        assertEq(market.pushRevenue(), 600_000);
        assertEq(staking.lastSourceTag(), bytes32("agent.offers"));
        assertEq(usdc.balanceOf(address(staking)), 6_000_000);
        _assertBooks(market);
    }

    function test_pushEarnings_withNothingOwedOrHeldIsRefused() public {
        vm.expectRevert(AgentOfferStakingPayout.NothingToPush.selector);
        earnings.pushEarnings();

        _earn(0, FLOOR);
        earnings.pushEarnings();
        vm.expectRevert(AgentOfferStakingPayout.NothingToPush.selector);
        earnings.pushEarnings();
    }

    /// @dev Nothing owed: the market is not asked (its claim would revert), and what is held goes in.
    function test_pushEarnings_depositsUSDCSentHereWhenNothingIsOwed() public {
        usdc.mint(address(earnings), 1_000_000);

        vm.expectCall(address(market), abi.encodeCall(IAgentOfferMarket.claim, (address(earnings))), 0);
        vm.expectEmit(address(earnings));
        emit AgentOfferStakingPayout.EarningsPushed(stranger, 0, 1_000_000);
        vm.prank(stranger);
        assertEq(earnings.pushEarnings(), 1_000_000);

        assertEq(usdc.balanceOf(address(staking)), 1_000_000);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        assertEq(usdc.allowance(address(earnings), address(staking)), 0);
    }

    function test_pushEarnings_depositsWhatIsOwedAndWhatIsHeldTogether() public {
        uint256 owed = _earn(0, 7_000_000);
        usdc.mint(address(earnings), 250_000);

        vm.expectEmit(address(earnings));
        emit AgentOfferStakingPayout.EarningsPushed(stranger, owed, owed + 250_000);
        vm.prank(stranger);
        assertEq(earnings.pushEarnings(), owed + 250_000);

        assertEq(usdc.balanceOf(address(staking)), owed + 250_000);
        assertEq(market.claimable(address(earnings)), 0);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        _assertBooks(market);
    }

    function test_aPausedStakingContractLeavesTheEarningsOwedInTheMarket() public {
        uint256 owed = _earn(0, 6_000_000);
        uint256 marketHeld = usdc.balanceOf(address(market));
        staking.setPaused(true);

        vm.expectRevert("PAUSED");
        vm.prank(stranger);
        earnings.pushEarnings();
        assertEq(market.claimable(address(earnings)), owed);
        assertEq(usdc.balanceOf(address(market)), marketHeld);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        assertEq(usdc.allowance(address(earnings), address(staking)), 0);
        _assertBooks(market);

        staking.setPaused(false);
        assertEq(earnings.pushEarnings(), owed);
        assertEq(market.claimable(address(earnings)), 0);
    }

    /// @dev Any earnings and any USDC already held: a push deposits exactly their sum and leaves
    ///      the contract empty with no allowance.
    function testFuzz_pushEarnings_depositsExactlyWhatIsOwedAndHeld(uint256 paid, uint256 held) public {
        paid = bound(paid, FLOOR, 1e15);
        held = bound(held, 0, 1e15);
        uint256 owed = _earn(0, paid);
        usdc.mint(address(earnings), held);

        assertEq(earnings.pushEarnings(), owed + held);
        assertEq(usdc.balanceOf(address(staking)), owed + held);
        assertEq(market.claimable(address(earnings)), 0);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        assertEq(usdc.allowance(address(earnings), address(staking)), 0);
        _assertBooks(market);
    }
}

/// @notice A staking contract that calls back into the payout contract from inside its deposit,
///         before pulling, while the payout still holds the money and its approval stands.
contract ReenteringStaking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    AgentOfferStakingPayout internal target;
    bytes public reentryError;
    uint256 public deposits;
    uint256 public received;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function aim(AgentOfferStakingPayout target_) external {
        target = target_;
    }

    function depositUSDC(uint256 amount, bytes32, bytes32) external returns (uint256) {
        try target.pushEarnings() {}
        catch (bytes memory reason) {
            reentryError = reason;
        }
        require(usdc.transferFrom(msg.sender, address(this), amount), "PULL_FAILED");
        ++deposits;
        received += amount;
        return amount;
    }
}

/// @title AgentOfferStakingPayoutReentrancyTest
/// @notice A staking contract that calls back mid-deposit gains nothing: the call is refused, and
///         the earnings arrive once.
contract AgentOfferStakingPayoutReentrancyTest is StakingPayoutBase {
    ReenteringStaking internal attacker;

    /// @dev A factory whose staking contract is the attacker; the kit's own factory goes unused.
    function setUp() public {
        _deployFactory(new FreezableUSDC());
        attacker = new ReenteringStaking(IERC20(BASE_USDC));
        factory = new AgentOfferFactory(admin, publisher, attacker, FEE_BPS);
        _deployPayoutAndMarket();
        attacker.aim(earnings);
    }

    function test_aStakingContractCallingBackGainsNothing() public {
        uint256 owed = _earn(0, 6_000_000);
        usdc.mint(address(earnings), 1);

        assertEq(earnings.pushEarnings(), owed + 1);

        assertEq(
            attacker.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(attacker.deposits(), 1);
        assertEq(attacker.received(), owed + 1);
        assertEq(usdc.balanceOf(address(attacker)), owed + 1);
        assertEq(market.claimable(address(earnings)), 0);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        assertEq(usdc.allowance(address(earnings), address(attacker)), 0);
        _assertBooks(market);
    }
}
