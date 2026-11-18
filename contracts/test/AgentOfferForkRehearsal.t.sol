// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {AgentOfferStakingPayout} from "../src/AgentOfferStakingPayout.sol";
import {IAgentOfferMarket} from "../src/IAgentOfferMarket.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {AgentOfferBase, FreezableUSDC} from "./AgentOfferTestKit.sol";

/// @notice The books of the live REGENT revenue staking contract that a deposit moves, and the two
///         figures its split between stakers and treasury follows.
interface IRegentStakingBooks {
    function paused() external view returns (bool);
    function totalUsdcReceived() external view returns (uint256);
    function directDepositUsdc() external view returns (uint256);
    function totalUsdcCreditedToStakers() external view returns (uint256);
    function treasuryResidualUsdc() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function revenueShareSupplyDenominator() external view returns (uint256);
}

/// @title AgentOfferForkRehearsalTest
/// @notice Rehearses the offer contracts' whole money path on a private fork of Base mainnet, with
///         Circle's real USDC and the live REGENT revenue staking contract: the factory as it would
///         be deployed, Patchbay's market paying its staking payout contract, a second publisher's
///         market paying a plain wallet, a sale, a buyout, a lease run to its end, a placement
///         terminated early, every claim, the fees and Patchbay's earnings pushed into staking, and
///         every unit of USDC accounted for at the end.
/// @dev Needs BASE_RPC_URL (Base's public endpoint is enough); without it the suite is skipped, so
///      `forge test` stays offline. The fork is pinned to `FORK_BLOCK`, so every run meets the same
///      chain. Nothing is broadcast. Timeline from the fork's own time T0: four sales at T0, the
///      CVE placement terminated at T0 + 18h, the buyout and the site lease's end at T0 + 24h, and
///      the bought-out lease's end at T0 + 96h.
contract AgentOfferForkRehearsalTest is AgentOfferBase {
    uint256 internal constant FORK_BLOCK = 57_430_000;

    /// @dev The live REGENT revenue staking contract on Base, as `script/Sanity.s.sol` names it.
    address internal constant REGENT_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;

    bytes32 internal constant SITE_SOURCE = keccak256("site.example");

    /// @dev The staking contract's deposit event; its `RevenueSourceKind` enum is a uint8 in the ABI.
    bytes32 internal constant REVENUE_DEPOSITED =
        keccak256("USDCRevenueDeposited(uint256,uint256,uint256,uint8,address,bytes32,bytes32)");

    struct StakingBooks {
        uint256 balance;
        uint256 received;
        uint256 direct;
        uint256 split;
    }

    AgentOfferStakingPayout internal earnings;
    address internal stranger = makeAddr("rehearsal.stranger");

    AgentOfferMarket internal siteMarket;
    address internal siteOperator;
    uint256 internal siteKey;
    address internal sitePayout = makeAddr("rehearsal.site-payout");

    uint256 internal general;
    uint256 internal cve;
    uint256 internal sitePlacement;

    address internal a1;
    uint256 internal a1Key;
    address internal a2 = makeAddr("rehearsal.advertiser-2");
    address internal a3 = makeAddr("rehearsal.advertiser-3");
    address internal a4 = makeAddr("rehearsal.advertiser-4");
    address internal a5 = makeAddr("rehearsal.advertiser-5");

    StakingBooks internal stakingAtStart;
    mapping(address market => uint256 amountUSDC) internal paidIn;
    mapping(address market => uint256 amountUSDC) internal claimedOut;
    mapping(address market => uint256 amountUSDC) internal pushedOut;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "BASE_RPC_URL is not set");
        vm.createSelectFork(rpc, FORK_BLOCK);

        // Only the token's ERC-20 functions are used: this is Circle's real USDC, not the stand-in.
        usdc = FreezableUSDC(BASE_USDC);
        (publisher, publisherKey) = makeAddrAndKey("rehearsal.publisher");
        (siteOperator, siteKey) = makeAddrAndKey("rehearsal.site-operator");
        (a1, a1Key) = makeAddrAndKey("rehearsal.advertiser-1");
        stakingAtStart = _stakingBooks();
    }

    function test_rehearsal_wholeMoneyPathOnBaseFork() public {
        assertEq(block.chainid, 8453);
        IRegentStakingBooks books = IRegentStakingBooks(REGENT_STAKING);
        assertFalse(books.paused(), "staking paused at the fork block");
        console2.log("fork block", block.number, "time T0", block.timestamp);
        console2.log("staking", REGENT_STAKING, "USDC held at T0", stakingAtStart.balance);
        console2.log("staked", books.totalStaked(), "of", books.revenueShareSupplyDenominator());

        _deployFactoryAndMarkets();
        _createPlacements();
        _firstSales();
        _terminateCveEarly();
        _buyoutAndNaturalEnds();
        _siteWalletClaims();
        _pushIntoStaking();
        _assertConserved();
    }

    // ---------------------------------------------------------------- steps

    /// @dev Step 1, with the step 8 refusals of a market for a non-admitted address and a second
    ///      market for one publisher. Patchbay's market is created in the README's order: predict its
    ///      address, deploy its staking payout contract, then create the market naming that contract.
    function _deployFactoryAndMarkets() internal {
        factory = new AgentOfferFactory(admin, operator, publisher, IRegentRevenueStaking(REGENT_STAKING), FEE_BPS);
        _logGas("factory deploy", _txGas());

        address predicted = factory.predictMarket(publisher);
        assertEq(predicted.code.length, 0, "no market before createMarket");
        earnings = new AgentOfferStakingPayout(factory, publisher);
        _logGas("staking payout deploy", _txGas());
        assertEq(address(earnings.market()), predicted);
        assertEq(address(earnings.usdc()), BASE_USDC);
        assertEq(address(earnings.staking()), REGENT_STAKING);
        payout = address(earnings);

        vm.prank(publisher);
        market = AgentOfferMarket(factory.createMarket(payout));
        _logGas("createMarket", _txGas());
        assertEq(address(market), predicted, "predictMarket");
        assertEq(factory.marketOf(publisher), predicted);
        assertEq(address(market.usdc()), BASE_USDC);
        assertEq(address(market.staking()), REGENT_STAKING);
        assertEq(market.payout(), address(earnings));
        assertEq(market.feeBps(), FEE_BPS);
        assertEq(usdc.balanceOf(address(market)), 0);

        vm.expectRevert(AgentOfferFactory.PublisherNotAllowed.selector);
        vm.prank(siteOperator);
        factory.createMarket(sitePayout);

        vm.expectRevert(AgentOfferFactory.MarketAlreadyExists.selector);
        vm.prank(publisher);
        factory.createMarket(payout);

        vm.prank(admin);
        factory.setPublisherAllowed(siteOperator, true);
        vm.prank(siteOperator);
        siteMarket = AgentOfferMarket(factory.createMarket(sitePayout));
        assertEq(address(siteMarket), factory.predictMarket(siteOperator));
        console2.log("factory", address(factory));
        console2.log("patchbay market", address(market), "staking payout", address(earnings));
        console2.log("site market", address(siteMarket), "payout wallet", sitePayout);
    }

    /// @dev Step 2: Patchbay's "General" and "CVE incidents" placements on its own terms, and the
    ///      site's placement on terms of its own.
    function _createPlacements() internal {
        vm.startPrank(publisher);
        general = market.createPlacement(SOURCE, _terms(CAPACITY, DURATION, BUMP_BPS, FLOOR), "ipfs://general");
        _logGas("createPlacement", _txGas());
        cve = market.createPlacement(SOURCE, _terms(CAPACITY, DURATION, BUMP_BPS, FLOOR), "ipfs://cve-incidents");
        vm.stopPrank();

        vm.prank(siteOperator);
        sitePlacement = siteMarket.createPlacement(SITE_SOURCE, _terms(2, 24 hours, 2_000, 1_000_000), "ipfs://site");
        assertEq(general, 1);
        assertEq(cve, 2);
        assertEq(sitePlacement, 1);
    }

    /// @dev Step 2's sales at T0, after the step 8 refusals of an expired admission and one the
    ///      advertiser signed itself.
    function _firstSales() internal {
        IAgentOfferMarket.Purchase memory p = _purchase(market, a1, general, 0, 9_000_000);
        uint64 deadline = p.deadline;
        p.deadline = SafeCast.toUint64(vm.getBlockTimestamp() - 1);
        bytes memory permit = _permit(market, p, a1);
        vm.expectRevert(IAgentOfferMarket.PurchaseExpired.selector);
        vm.prank(a1);
        market.buy(p, permit);

        p.deadline = deadline;
        permit = _sign(a1Key, _digest(market, p, a1));
        vm.expectRevert(IAgentOfferMarket.InvalidPermit.selector);
        vm.prank(a1);
        market.buy(p, permit);

        _logGas("buy (empty slot)", _buyAs(market, publisherKey, a1, general, 0, 9_000_000));
        _buyAs(market, publisherKey, a3, cve, 1, 7_200_000);
        _buyAs(market, publisherKey, a4, cve, 0, 5_000_001);
        _buyAs(siteMarket, siteKey, a5, sitePlacement, 0, 1_000_000);

        assertEq(market.totalLeaseDeposits(), 21_200_001);
        assertEq(siteMarket.totalLeaseDeposits(), 1_000_000);
        _assertBooks(market);
        _assertBooks(siteMarket);
    }

    /// @dev Step 4, early end: at T0 + 18h only the publisher may terminate; anyone settles.
    function _terminateCveEarly() internal {
        skip(18 hours);
        vm.expectRevert(IAgentOfferMarket.NotPublisher.selector);
        vm.prank(stranger);
        market.terminatePlacement(cve);
        vm.prank(publisher);
        market.terminatePlacement(cve);

        vm.startPrank(stranger);
        market.settleTerminated(cve, 1);
        market.settleTerminated(cve, 0);
        vm.stopPrank();

        // 18 of 72 hours used. 7.2 USDC: 5.4 back, 1.8 earned, of which 0.18 is the fee.
        assertEq(market.claimable(a3), 5_400_000);
        // 5.000001 USDC: three quarters back is 3.75000075, rounded down to 3.75; 1.250001 earned,
        // whose fee 0.1250001 rounds down to 0.125, so the payout gets 1.125001.
        assertEq(market.claimable(a4), 3_750_000);
        assertEq(market.claimable(payout), 1_620_000 + 1_125_001);
        assertEq(market.revenueOwed(), 180_000 + 125_000);

        _claimAs(market, a4, 3_750_000);
        _assertBooks(market);
        console2.log("terminated CVE: refunds A3", uint256(5_400_000), "A4 (claimed)", uint256(3_750_000));
    }

    /// @dev Step 3 at T0 + 24h, then step 4's natural ends: the site lease at T0 + 24h and the
    ///      bought-out General lease at T0 + 96h.
    function _buyoutAndNaturalEnds() internal {
        skip(6 hours);
        assertEq(market.minimumPrice(general, 0), 9_900_000);
        _logGas("buy (buyout)", _buyAs(market, publisherKey, a2, general, 0, 9_900_000));

        // 48 of 72 hours unused: 6 USDC back to A1; 3 earned, of which 0.3 is the fee.
        assertEq(market.claimable(a1), 6_000_000);
        assertEq(market.claimable(payout), 2_745_001 + 2_700_000);
        assertEq(market.revenueOwed(), 305_000 + 300_000);
        _logGas("claim (advertiser wallet)", _claimAs(market, a1, 6_000_000));
        console2.log("buyout: A1 refund claimed", uint256(6_000_000));

        vm.prank(stranger);
        siteMarket.settleExpired(sitePlacement, 0);
        assertEq(siteMarket.claimable(a5), 0);
        assertEq(siteMarket.claimable(sitePayout), 900_000);
        assertEq(siteMarket.revenueOwed(), 100_000);

        skip(DURATION);
        vm.prank(stranger);
        market.settleExpired(general, 0);
        assertEq(market.claimable(a2), 0);
        assertEq(market.claimable(payout), 5_445_001 + 8_910_000);
        assertEq(market.revenueOwed(), 605_000 + 990_000);
        assertEq(market.totalLeaseDeposits(), 0);
        assertEq(siteMarket.totalLeaseDeposits(), 0);
        _assertBooks(market);
        _assertBooks(siteMarket);
    }

    /// @dev Step 5: the site's payout wallet claims its earnings itself.
    function _siteWalletClaims() internal {
        _claimAs(siteMarket, sitePayout, 900_000);
        console2.log("site wallet claimed", uint256(900_000));
    }

    /// @dev Step 6: the operator pushes each market's fee, and Patchbay's earnings through its
    ///      staking payout contract, into the live staking contract; a stranger is refused first.
    function _pushIntoStaking() internal {
        vm.expectRevert(IAgentOfferMarket.NotStakingSender.selector);
        vm.prank(stranger);
        market.pushRevenue();
        vm.expectRevert(AgentOfferStakingPayout.NotStakingSender.selector);
        vm.prank(stranger);
        earnings.pushEarnings();

        _logGas("pushRevenue (Patchbay market)", _pushFee(market, 1_595_000));
        _logGas("pushEarnings (Patchbay staking payout)", _pushEarnings(14_355_001));
        _pushFee(siteMarket, 100_000);
        console2.log("fees in staking: Patchbay", uint256(1_595_000), "site", uint256(100_000));
        console2.log("Patchbay earnings in staking", uint256(14_355_001));
    }

    /// @dev Step 7: every unit is accounted for. A3's refund is the one credit left unclaimed, and
    ///      everything Patchbay's market earned, its fee and its own share alike, is in staking.
    function _assertConserved() internal view {
        uint256 outstanding = market.claimable(a1) + market.claimable(a2) + market.claimable(a3) + market.claimable(a4)
            + market.claimable(address(earnings));
        assertEq(outstanding, 5_400_000);
        _assertMarketConserved(market, outstanding);
        _assertMarketConserved(siteMarket, siteMarket.claimable(a5) + siteMarket.claimable(sitePayout));

        // Claimed out of Patchbay's market: A1's 6 and A4's 3.75 refunds, and the staking payout's
        // 14.355001.
        assertEq(paidIn[address(market)], 31_100_001);
        assertEq(claimedOut[address(market)], 24_105_001);
        assertEq(pushedOut[address(market)], 1_595_000);
        assertEq(paidIn[address(siteMarket)], 1_000_000);
        assertEq(usdc.balanceOf(address(earnings)), 0, "nothing left in the staking payout");

        // 31.100001 paid in, less 15.15 refunded (A1 6, A4 3.75, A3 5.4), is 15.950001 earned: the
        // 1.595 fee and Patchbay's 14.355001. The site adds its 0.1 fee.
        assertEq(paidIn[address(market)] - (6_000_000 + 3_750_000 + 5_400_000), 1_595_000 + 14_355_001);
        uint256 intoStaking = 1_595_000 + 14_355_001 + 100_000;
        StakingBooks memory end = _stakingBooks();
        assertEq(end.balance - stakingAtStart.balance, intoStaking, "staking USDC balance");
        assertEq(end.received - stakingAtStart.received, intoStaking, "staking totalUsdcReceived");
        assertEq(end.direct - stakingAtStart.direct, intoStaking, "staking directDepositUsdc");
        assertEq(end.split - stakingAtStart.split, intoStaking, "staking stakers + treasury");

        console2.log("patchbay: in", paidIn[address(market)], "claimed", claimedOut[address(market)]);
        console2.log("patchbay: pushed", pushedOut[address(market)], "still claimable", outstanding);
        console2.log("site: in", paidIn[address(siteMarket)], "claimed", claimedOut[address(siteMarket)]);
        console2.log("site: pushed", pushedOut[address(siteMarket)], "still claimable", uint256(0));
        console2.log("staking: USDC in since T0", end.balance - stakingAtStart.balance);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Funds `buyer` with real USDC, approves the market, and buys with an admission signed by
    ///      `signerKey`. Returns the gas the purchase used.
    function _buyAs(AgentOfferMarket m, uint256 signerKey, address buyer, uint256 id, uint16 slot, uint256 amount)
        internal
        returns (uint256 gasUsed)
    {
        IAgentOfferMarket.Purchase memory p = _purchase(m, buyer, id, slot, amount);
        bytes memory permit = _sign(signerKey, _digest(m, p, buyer));
        uint256 before = usdc.balanceOf(buyer) + amount;
        deal(BASE_USDC, buyer, before);
        vm.prank(buyer);
        usdc.approve(address(m), amount);

        vm.prank(buyer);
        m.buy(p, permit);
        gasUsed = _txGas();
        assertEq(before - usdc.balanceOf(buyer), amount);
        paidIn[address(m)] += amount;
    }

    /// @dev `account` claims its credit to itself. Returns the gas the claim used.
    function _claimAs(AgentOfferMarket m, address account, uint256 expected) internal returns (uint256 gasUsed) {
        uint256 before = usdc.balanceOf(account);
        vm.prank(account);
        uint256 claimed = m.claim(account);
        gasUsed = _txGas();
        assertEq(claimed, expected);
        assertEq(usdc.balanceOf(account) - before, expected);
        assertEq(m.claimable(account), 0);
        claimedOut[address(m)] += expected;
    }

    /// @dev The operator pushes `m`'s fee: tagged `agent.offers`, with the market as both depositor
    ///      and reference, and no allowance left behind.
    function _pushFee(AgentOfferMarket m, uint256 fee) internal returns (uint256 gasUsed) {
        StakingBooks memory before = _stakingBooks();
        vm.recordLogs();
        vm.prank(operator);
        uint256 pushed = m.pushRevenue();
        gasUsed = _txGas();
        _assertDeposited(before, address(m), address(m), "agent.offers", fee);
        assertEq(pushed, fee);
        assertEq(m.revenueOwed(), 0);
        assertEq(usdc.allowance(address(m), REGENT_STAKING), 0);
        pushedOut[address(m)] += fee;
    }

    /// @dev The operator pushes Patchbay's earnings: the staking payout contract claims them from the
    ///      market and deposits them in the same call, tagged `agent.offers.payout`, with itself as
    ///      depositor and the market as reference, keeping nothing and leaving no allowance.
    function _pushEarnings(uint256 owed) internal returns (uint256 gasUsed) {
        StakingBooks memory before = _stakingBooks();
        vm.recordLogs();
        vm.prank(operator);
        uint256 pushed = earnings.pushEarnings();
        gasUsed = _txGas();
        _assertDeposited(before, address(earnings), address(market), "agent.offers.payout", owed);
        assertEq(pushed, owed);
        assertEq(market.claimable(address(earnings)), 0);
        assertEq(usdc.balanceOf(address(earnings)), 0);
        assertEq(usdc.allowance(address(earnings), REGENT_STAKING), 0);
        claimedOut[address(market)] += owed;
    }

    function _stakingBooks() internal view returns (StakingBooks memory books) {
        IRegentStakingBooks staking_ = IRegentStakingBooks(REGENT_STAKING);
        books.balance = usdc.balanceOf(REGENT_STAKING);
        books.received = staking_.totalUsdcReceived();
        books.direct = staking_.directDepositUsdc();
        books.split = staking_.totalUsdcCreditedToStakers() + staking_.treasuryResidualUsdc();
    }

    /// @dev Since `before`, the staking contract took exactly `amount` and recorded it as one direct
    ///      deposit from `depositor`, tagged `tag` with `ref` as reference, split between stakers and
    ///      its treasury. Logs the split.
    function _assertDeposited(StakingBooks memory before, address depositor, address ref, bytes32 tag, uint256 amount)
        internal
        view
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        StakingBooks memory afterPush = _stakingBooks();
        assertEq(afterPush.balance - before.balance, amount, "staking USDC balance");
        assertEq(afterPush.received - before.received, amount, "staking totalUsdcReceived");
        assertEq(afterPush.direct - before.direct, amount, "staking directDepositUsdc");
        assertEq(afterPush.split - before.split, amount, "staking stakers + treasury");

        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != REGENT_STAKING || logs[i].topics[0] != REVENUE_DEPOSITED) continue;
            ++found;
            assertEq(logs[i].topics[1], bytes32(0), "sourceKind DirectDeposit");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(depositor))), "depositor");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(ref))), "sourceRef is the market");
            (uint256 received, uint256 credited, uint256 treasury, bytes32 loggedTag) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, bytes32));
            assertEq(received, amount);
            assertEq(credited + treasury, amount);
            assertEq(loggedTag, tag);
            console2.log("  deposit", received, "to stakers", credited);
            console2.log("  to treasury", treasury);
        }
        assertEq(found, 1, "one deposit recorded");
    }

    /// @dev USDC in equals USDC out plus what is held, and what is held is exactly the credit still
    ///      owed: no lease deposit and no fee is left in the market.
    function _assertMarketConserved(AgentOfferMarket m, uint256 outstanding) internal view {
        uint256 held = usdc.balanceOf(address(m));
        assertEq(m.totalLeaseDeposits(), 0);
        assertEq(m.revenueOwed(), 0);
        assertEq(held, outstanding, "held equals the credit still owed");
        assertEq(held, m.totalClaimable());
        assertEq(paidIn[address(m)], claimedOut[address(m)] + pushedOut[address(m)] + held, "in = out + held");
    }

    /// @dev What the last call costs as a transaction of its own. Foundry runs each top-level call
    ///      from cold storage and counts its base cost and calldata in the frame's gas; a
    ///      transaction then gets its refund back, capped at a fifth of the gas used.
    function _txGas() internal view returns (uint256) {
        Vm.Gas memory frame = vm.lastFrameGas();
        uint256 refund = SafeCast.toUint256(frame.gasRefunded);
        uint256 cap = frame.gasTotalUsed / 5;
        return frame.gasTotalUsed - (refund < cap ? refund : cap);
    }

    function _logGas(string memory what, uint256 gasUsed) internal pure {
        console2.log(string.concat("gas ", what), gasUsed);
    }
}
