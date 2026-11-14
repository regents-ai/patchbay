// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {IAgentOfferMarket} from "../src/IAgentOfferMarket.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {AgentOfferBase, FreezableUSDC} from "./AgentOfferTestKit.sol";

/// @notice The books of the live REGENT revenue staking contract that a deposit moves.
interface IRegentStakingBooks {
    function paused() external view returns (bool);
    function totalUsdcReceived() external view returns (uint256);
    function directDepositUsdc() external view returns (uint256);
    function totalUsdcCreditedToStakers() external view returns (uint256);
    function treasuryResidualUsdc() external view returns (uint256);
}

/// @notice A minimal stand-in for a Safe: it makes whatever call its owner has approved, as a Safe
///         does once its signers have signed a transaction.
contract PayoutSafe {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "NOT_OWNER");
        return Address.functionCall(target, data);
    }
}

/// @title AgentOfferForkRehearsalTest
/// @notice Rehearses the offer contracts' whole money path on a private fork of Base mainnet, with
///         Circle's real USDC and the live REGENT revenue staking contract: the factory as it would
///         be deployed, Patchbay's market paying a Safe, a second publisher's market paying a plain
///         wallet, a sale, a buyout, a lease run to its end, a placement terminated early, every
///         claim, the fee pushed into staking, and every unit of USDC accounted for at the end.
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

    PayoutSafe internal safe;
    address internal safeOwner = makeAddr("rehearsal.safe-owner");
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

    uint256 internal stakingAtStart;
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
        safe = new PayoutSafe(safeOwner);
        payout = address(safe);
        stakingAtStart = usdc.balanceOf(REGENT_STAKING);
    }

    function test_rehearsal_wholeMoneyPathOnBaseFork() public {
        assertEq(block.chainid, 8453);
        assertFalse(IRegentStakingBooks(REGENT_STAKING).paused(), "staking paused at the fork block");
        console2.log("fork block", block.number, "time T0", block.timestamp);
        console2.log("staking", REGENT_STAKING, "USDC held at T0", stakingAtStart);

        _deployFactoryAndMarkets();
        _createPlacements();
        _firstSales();
        _terminateCveEarly();
        _buyoutAndNaturalEnds();
        _payoutsClaim();
        _pushRevenue();
        _assertConserved();
    }

    // ---------------------------------------------------------------- steps

    /// @dev Step 1, with the step 8 refusals of a market for a non-admitted address and a second
    ///      market for one publisher.
    function _deployFactoryAndMarkets() internal {
        factory = new AgentOfferFactory(admin, publisher, IRegentRevenueStaking(REGENT_STAKING), FEE_BPS);
        _logGas("factory deploy", _txGas());

        address predicted = factory.predictMarket(publisher);
        vm.prank(publisher);
        market = AgentOfferMarket(factory.createMarket(payout));
        _logGas("createMarket", _txGas());
        assertEq(address(market), predicted, "predictMarket");
        assertEq(factory.marketOf(publisher), predicted);
        assertEq(address(market.usdc()), BASE_USDC);
        assertEq(address(market.staking()), REGENT_STAKING);
        assertEq(market.payout(), address(safe));
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
        console2.log("patchbay market", address(market), "payout safe", address(safe));
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

    /// @dev Step 5: Patchbay's Safe claims through a Safe transaction; the site's wallet directly.
    function _payoutsClaim() internal {
        uint256 before = usdc.balanceOf(address(safe));
        vm.prank(safeOwner);
        safe.execute(address(market), abi.encodeCall(IAgentOfferMarket.claim, (address(safe))));
        _logGas("claim (payout Safe, whole Safe call)", _txGas());
        assertEq(usdc.balanceOf(address(safe)) - before, 14_355_001);
        assertEq(market.claimable(address(safe)), 0);
        claimedOut[address(market)] += 14_355_001;

        _claimAs(siteMarket, sitePayout, 900_000);
        console2.log("payouts claimed: Patchbay Safe", uint256(14_355_001), "site wallet", uint256(900_000));
    }

    /// @dev Step 6: anyone pushes each market's fee into the live staking contract.
    function _pushRevenue() internal {
        _logGas("pushRevenue (Patchbay market)", _push(market, 1_595_000));
        _push(siteMarket, 100_000);
        console2.log("fees in staking: Patchbay", uint256(1_595_000), "site", uint256(100_000));
    }

    /// @dev Step 7: every unit is accounted for. A3's refund is the one credit left unclaimed.
    function _assertConserved() internal view {
        uint256 outstanding = market.claimable(a1) + market.claimable(a2) + market.claimable(a3) + market.claimable(a4)
            + market.claimable(address(safe));
        assertEq(outstanding, 5_400_000);
        _assertMarketConserved(market, outstanding);
        _assertMarketConserved(siteMarket, siteMarket.claimable(a5) + siteMarket.claimable(sitePayout));

        assertEq(paidIn[address(market)], 31_100_001);
        assertEq(claimedOut[address(market)], 24_105_001);
        assertEq(pushedOut[address(market)], 1_595_000);
        assertEq(paidIn[address(siteMarket)], 1_000_000);
        assertEq(usdc.balanceOf(REGENT_STAKING) - stakingAtStart, 1_695_000, "staking received exactly the fees");

        console2.log("patchbay: in", paidIn[address(market)], "claimed", claimedOut[address(market)]);
        console2.log("patchbay: pushed", pushedOut[address(market)], "still claimable", outstanding);
        console2.log("site: in", paidIn[address(siteMarket)], "claimed", claimedOut[address(siteMarket)]);
        console2.log("site: pushed", pushedOut[address(siteMarket)], "still claimable", uint256(0));
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

    /// @dev A stranger pushes `m`'s fee. The staking contract must take exactly the fee, record it as
    ///      a direct deposit split between stakers and its treasury, tagged `agent.offers` with the
    ///      market as both depositor and reference, and leave no allowance behind.
    function _push(AgentOfferMarket m, uint256 fee) internal returns (uint256 gasUsed) {
        StakingBooks memory before = _stakingBooks();
        vm.recordLogs();
        vm.prank(stranger);
        uint256 pushed = m.pushRevenue();
        gasUsed = _txGas();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        StakingBooks memory afterPush = _stakingBooks();
        assertEq(pushed, fee);
        assertEq(m.revenueOwed(), 0);
        assertEq(usdc.allowance(address(m), REGENT_STAKING), 0);
        assertEq(afterPush.balance - before.balance, fee, "staking USDC balance");
        assertEq(afterPush.received - before.received, fee, "staking totalUsdcReceived");
        assertEq(afterPush.direct - before.direct, fee, "staking directDepositUsdc");
        assertEq(afterPush.split - before.split, fee, "staking stakers + treasury");
        _assertDepositRecorded(logs, address(m), fee);
        pushedOut[address(m)] += fee;
    }

    function _stakingBooks() internal view returns (StakingBooks memory books) {
        IRegentStakingBooks staking_ = IRegentStakingBooks(REGENT_STAKING);
        books.balance = usdc.balanceOf(REGENT_STAKING);
        books.received = staking_.totalUsdcReceived();
        books.direct = staking_.directDepositUsdc();
        books.split = staking_.totalUsdcCreditedToStakers() + staking_.treasuryResidualUsdc();
    }

    function _assertDepositRecorded(Vm.Log[] memory logs, address m, uint256 fee) internal pure {
        bytes32 asTopic = bytes32(uint256(uint160(m)));
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != REGENT_STAKING || logs[i].topics[0] != REVENUE_DEPOSITED) continue;
            ++found;
            assertEq(logs[i].topics[1], bytes32(0), "sourceKind DirectDeposit");
            assertEq(logs[i].topics[2], asTopic, "depositor is the market");
            assertEq(logs[i].topics[3], asTopic, "sourceRef is the market");
            (uint256 received, uint256 credited, uint256 treasury, bytes32 tag) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, bytes32));
            assertEq(received, fee);
            assertEq(credited + treasury, fee);
            assertEq(tag, bytes32("agent.offers"));
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
