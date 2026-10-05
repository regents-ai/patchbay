// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";
import {PatchbayOffersEscrow} from "../src/PatchbayOffersEscrow.sol";
import {TestStaking} from "./PatchbayEscrow.t.sol";

/// @notice A six-decimal token standing in for Base USDC, with EIP-3009 `receiveWithAuthorization`
///         as Circle's FiatToken v2.2 has it: the caller must be the payee, the authorization must
///         be inside its time window, a nonce is spent once per signer, and the signature is checked
///         as an ordinary signature or, for a contract wallet, through ERC-1271.
contract TestUSDC3009 is ERC20, EIP712 {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address authorizer => mapping(bytes32 nonce => bool used)) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") EIP712("USD Coin", "2") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function digest(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationState[from][nonce], "FiatTokenV2: authorization is used or canceled");
        require(
            SignatureChecker.isValidSignatureNow(
                from, digest(from, to, value, validAfter, validBefore, nonce), signature
            ),
            "FiatTokenV2: invalid signature"
        );
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }
}

/// @notice A smart-contract wallet that accepts any signature its owner key made.
contract TestSmartWallet is IERC1271 {
    address internal immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered,,) = ECDSA.tryRecover(hash, signature);
        return recovered == signer ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @notice Shared set-up: the escrow, a stand-in USDC and staking contract, and a bidder whose
///         wallet signs authorizations.
abstract contract OffersEscrowSetup is Test {
    TestUSDC3009 internal usdc;
    TestStaking internal staking;
    PatchbayOffersEscrow internal escrow;

    address internal operator = makeAddr("operator");
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal bidder;
    uint256 internal bidderKey;

    uint256 internal constant WINDOW = 2 minutes;

    function setUp() public virtual {
        usdc = new TestUSDC3009();
        staking = new TestStaking(IERC20(address(usdc)));
        escrow = new PatchbayOffersEscrow(IERC20(address(usdc)), staking, operator, owner);
        (bidder, bidderKey) = makeAddrAndKey("bidder");
    }

    /// @dev What the bidder's wallet signs when they press a bid button.
    function _sign(uint256 key, address from, uint256 amount, bytes32 bidId, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash = usdc.digest(from, address(escrow), amount, 0, validBefore, bidId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Funds the bidder and commits one bid through the operator.
    function _commit(bytes32 bidId, uint96 amount) internal {
        usdc.mint(bidder, amount);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, amount, bidId, validBefore);
        vm.prank(operator);
        escrow.commit(bidId, bidder, amount, 0, validBefore, signature);
    }
}

/// @title PatchbayOffersEscrowTest
/// @notice What the Offers escrow promises about money: a bid's amount and id are fixed by the
///         bidder's own signature; each bid is committed once and settled once; a lost bid comes
///         back in full; a settlement's parts add up to the bid, with the returned part going only
///         to the bidder; an unsettled bid can be sent back to its bidder by anyone after 14 days;
///         and the revenue reaches stakers without a paused staking contract holding up a bidder.
contract PatchbayOffersEscrowTest is OffersEscrowSetup {
    bytes32 internal constant BID = keccak256("bid-1");
    uint96 internal constant AMOUNT = 10_010_000;

    event Committed(bytes32 indexed bidId, address indexed payer, uint96 amount, uint64 committedAt);
    event Released(bytes32 indexed bidId, address indexed payer, uint256 amount);
    event Settled(bytes32 indexed bidId, address indexed payer, uint256 returned, uint256 consumed, uint256 forfeited);
    event Reclaimed(bytes32 indexed bidId, address indexed payer, uint256 amount, address indexed caller);
    event RevenuePushed(address indexed caller, uint256 amount);

    function test_constructor_fixesTheStakingContractAndOwner() public {
        assertEq(address(escrow.staking()), address(staking));
        assertEq(address(escrow.usdc()), address(usdc));
        assertEq(escrow.owner(), owner);
        assertEq(escrow.operator(), operator);
        assertEq(escrow.SOURCE_TAG(), bytes32("patchbay.offers"));
        assertEq(escrow.RECLAIM_DELAY(), 14 days);

        vm.expectRevert(PatchbayOffersEscrow.ZeroAddress.selector);
        new PatchbayOffersEscrow(IERC20(address(usdc)), IRegentRevenueStaking(address(0)), operator, owner);
    }

    function test_onlyTheOwnerSetsTheOperator() public {
        address next = makeAddr("next-operator");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        escrow.setOperator(next);

        vm.prank(owner);
        escrow.setOperator(next);
        assertEq(escrow.operator(), next);
    }

    function test_commit_pullsTheBidFromTheBiddersWallet() public {
        usdc.mint(bidder, AMOUNT);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, AMOUNT, BID, validBefore);

        vm.expectEmit(true, true, false, true);
        emit Committed(BID, bidder, AMOUNT, uint64(block.timestamp));
        vm.prank(operator);
        escrow.commit(BID, bidder, AMOUNT, 0, validBefore, signature);

        (address payer, uint96 amount, PatchbayOffersEscrow.Status status, uint64 committedAt) = escrow.commitments(BID);
        assertEq(payer, bidder);
        assertEq(amount, AMOUNT);
        assertEq(uint8(status), uint8(PatchbayOffersEscrow.Status.Committed));
        assertEq(committedAt, uint64(block.timestamp));
        assertEq(escrow.totalCommitted(), AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
        assertEq(usdc.balanceOf(bidder), 0);
    }

    function test_commit_isOperatorOnly() public {
        usdc.mint(bidder, AMOUNT);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, AMOUNT, BID, validBefore);

        vm.expectRevert(PatchbayOffersEscrow.NotOperator.selector);
        vm.prank(stranger);
        escrow.commit(BID, bidder, AMOUNT, 0, validBefore, signature);
    }

    function test_commit_theSignatureFixesTheAmountAndTheBid() public {
        usdc.mint(bidder, AMOUNT * 2);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, AMOUNT, BID, validBefore);

        vm.startPrank(operator);
        vm.expectRevert("FiatTokenV2: invalid signature");
        escrow.commit(BID, bidder, AMOUNT + 1, 0, validBefore, signature);

        vm.expectRevert("FiatTokenV2: invalid signature");
        escrow.commit(keccak256("another-bid"), bidder, AMOUNT, 0, validBefore, signature);

        vm.expectRevert("FiatTokenV2: invalid signature");
        escrow.commit(BID, stranger, AMOUNT, 0, validBefore, signature);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bidder), AMOUNT * 2);
        assertEq(escrow.totalCommitted(), 0);
    }

    /// @dev A repeat press on the same quote signs the same bid: its second commit moves nothing.
    function test_commit_aBidIsCommittedOnce() public {
        usdc.mint(bidder, AMOUNT * 2);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, AMOUNT, BID, validBefore);

        vm.startPrank(operator);
        escrow.commit(BID, bidder, AMOUNT, 0, validBefore, signature);
        vm.expectRevert(PatchbayOffersEscrow.AlreadyCommitted.selector);
        escrow.commit(BID, bidder, AMOUNT, 0, validBefore, signature);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bidder), AMOUNT);
        assertEq(escrow.totalCommitted(), AMOUNT);
    }

    function test_commit_anExpiredAuthorizationMovesNothing() public {
        usdc.mint(bidder, AMOUNT);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, AMOUNT, BID, validBefore);

        vm.warp(validBefore);
        vm.expectRevert("FiatTokenV2: authorization is expired");
        vm.prank(operator);
        escrow.commit(BID, bidder, AMOUNT, 0, validBefore, signature);

        (,, PatchbayOffersEscrow.Status status,) = escrow.commitments(BID);
        assertEq(uint8(status), uint8(PatchbayOffersEscrow.Status.None));
    }

    /// @dev The bidder moved their USDC away after signing: the commit fails and the bid is unfunded.
    function test_commit_failsWhenTheUSDCIsGone() public {
        usdc.mint(bidder, AMOUNT);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, bidder, AMOUNT, BID, validBefore);
        vm.prank(bidder);
        assertTrue(usdc.transfer(stranger, 1));

        vm.expectRevert();
        vm.prank(operator);
        escrow.commit(BID, bidder, AMOUNT, 0, validBefore, signature);
        assertEq(escrow.totalCommitted(), 0);
    }

    function test_commit_rejectsAZeroAmountAndAZeroPayer() public {
        vm.startPrank(operator);
        vm.expectRevert(PatchbayOffersEscrow.ZeroAmount.selector);
        escrow.commit(BID, bidder, 0, 0, block.timestamp + WINDOW, "");

        vm.expectRevert(PatchbayOffersEscrow.ZeroAddress.selector);
        escrow.commit(BID, address(0), AMOUNT, 0, block.timestamp + WINDOW, "");
        vm.stopPrank();
    }

    function test_commit_aSmartWalletCanBid() public {
        TestSmartWallet wallet = new TestSmartWallet(bidder);
        usdc.mint(address(wallet), AMOUNT);
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory signature = _sign(bidderKey, address(wallet), AMOUNT, BID, validBefore);

        vm.prank(operator);
        escrow.commit(BID, address(wallet), AMOUNT, 0, validBefore, signature);

        vm.prank(operator);
        escrow.release(BID);
        assertEq(usdc.balanceOf(address(wallet)), AMOUNT);
    }

    function test_release_sendsTheWholeBidBackOnce() public {
        _commit(BID, AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Released(BID, bidder, AMOUNT);
        vm.prank(operator);
        escrow.release(BID);

        assertEq(usdc.balanceOf(bidder), AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalCommitted(), 0);
        assertEq(escrow.revenueOwed(), 0);

        vm.startPrank(operator);
        vm.expectRevert(PatchbayOffersEscrow.NotCommitted.selector);
        escrow.release(BID);
        vm.expectRevert(PatchbayOffersEscrow.NotCommitted.selector);
        escrow.settle(BID, 0, AMOUNT, 0);
        vm.stopPrank();
    }

    function test_releaseAndSettle_areOperatorOnly() public {
        _commit(BID, AMOUNT);

        vm.startPrank(stranger);
        vm.expectRevert(PatchbayOffersEscrow.NotOperator.selector);
        escrow.release(BID);
        vm.expectRevert(PatchbayOffersEscrow.NotOperator.selector);
        escrow.settle(BID, AMOUNT, 0, 0);
        vm.stopPrank();
    }

    /// @dev A buyout: the unused part goes back, the time shown is revenue.
    function test_settle_returnsTheUnusedPartAndKeepsTheRest() public {
        _commit(BID, AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit Settled(BID, bidder, 6_000_000, 4_010_000, 0);
        vm.prank(operator);
        escrow.settle(BID, 6_000_000, 4_010_000, 0);

        assertEq(usdc.balanceOf(bidder), 6_000_000);
        assertEq(escrow.revenueOwed(), 4_010_000);
        assertEq(escrow.totalCommitted(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 4_010_000);

        vm.expectRevert(PatchbayOffersEscrow.NotCommitted.selector);
        vm.prank(operator);
        escrow.settle(BID, 6_000_000, 4_010_000, 0);
    }

    /// @dev A full run and a moderator's removal both return nothing.
    function test_settle_withNothingReturned() public {
        _commit(BID, AMOUNT);
        _commit(keccak256("bid-2"), AMOUNT);

        vm.startPrank(operator);
        escrow.settle(BID, 0, AMOUNT, 0);
        escrow.settle(keccak256("bid-2"), 0, 3_000_000, AMOUNT - 3_000_000);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bidder), 0);
        assertEq(escrow.revenueOwed(), AMOUNT * 2);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT * 2);
    }

    function test_settle_thePartsMustAddUpToTheBid() public {
        _commit(BID, AMOUNT);

        vm.startPrank(operator);
        vm.expectRevert(PatchbayOffersEscrow.PartsDoNotAddUp.selector);
        escrow.settle(BID, AMOUNT, 1, 0);
        vm.expectRevert(PatchbayOffersEscrow.PartsDoNotAddUp.selector);
        escrow.settle(BID, 0, AMOUNT - 1, 0);
        vm.stopPrank();
    }

    function test_reclaim_isRefusedBeforeFourteenDays() public {
        _commit(BID, AMOUNT);

        vm.warp(block.timestamp + 14 days - 1);
        vm.expectRevert(PatchbayOffersEscrow.ReclaimTooEarly.selector);
        vm.prank(bidder);
        escrow.reclaim(BID);
    }

    function test_reclaim_afterFourteenDaysAnyoneSendsTheWholeBidBack() public {
        _commit(BID, AMOUNT);
        vm.warp(block.timestamp + 14 days);

        vm.expectEmit(true, true, true, true);
        emit Reclaimed(BID, bidder, AMOUNT, stranger);
        vm.prank(stranger);
        escrow.reclaim(BID);

        assertEq(usdc.balanceOf(bidder), AMOUNT);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(escrow.totalCommitted(), 0);

        vm.expectRevert(PatchbayOffersEscrow.NotCommitted.selector);
        vm.prank(operator);
        escrow.settle(BID, 0, AMOUNT, 0);
    }

    function test_reclaim_isRefusedOnceSettledOrReleased() public {
        _commit(BID, AMOUNT);
        _commit(keccak256("bid-2"), AMOUNT);
        vm.startPrank(operator);
        escrow.settle(BID, 0, AMOUNT, 0);
        escrow.release(keccak256("bid-2"));
        vm.stopPrank();

        vm.warp(block.timestamp + 14 days);
        vm.expectRevert(PatchbayOffersEscrow.NotCommitted.selector);
        escrow.reclaim(BID);
        vm.expectRevert(PatchbayOffersEscrow.NotCommitted.selector);
        escrow.reclaim(keccak256("bid-2"));
    }

    function test_pushRevenue_depositsAllThatIsOwedTaggedForAnyCaller() public {
        _commit(BID, AMOUNT);
        vm.prank(operator);
        escrow.settle(BID, 1_000_000, AMOUNT - 1_000_000, 0);

        vm.expectEmit(true, false, false, true);
        emit RevenuePushed(stranger, AMOUNT - 1_000_000);
        vm.prank(stranger);
        assertEq(escrow.pushRevenue(), AMOUNT - 1_000_000);

        assertEq(usdc.balanceOf(address(staking)), AMOUNT - 1_000_000);
        assertEq(staking.lastSourceTag(), bytes32("patchbay.offers"));
        assertEq(escrow.revenueOwed(), 0);
        assertEq(usdc.allowance(address(escrow), address(staking)), 0);

        vm.expectRevert(PatchbayOffersEscrow.NothingOwed.selector);
        escrow.pushRevenue();
    }

    function test_aPausedStakingContractHoldsUpOnlyThePush() public {
        _commit(BID, AMOUNT);
        _commit(keccak256("bid-2"), AMOUNT);
        vm.prank(operator);
        escrow.settle(BID, 0, AMOUNT, 0);
        staking.setPaused(true);

        vm.expectRevert("PAUSED");
        escrow.pushRevenue();
        assertEq(escrow.revenueOwed(), AMOUNT);

        vm.prank(operator);
        escrow.release(keccak256("bid-2"));
        assertEq(usdc.balanceOf(bidder), AMOUNT);

        staking.setPaused(false);
        escrow.pushRevenue();
        assertEq(usdc.balanceOf(address(staking)), AMOUNT);
    }

    /// @dev Whatever three parts the operator names, they add up to the bid or nothing moves, and
    ///      the bidder plus the revenue owed account for every base unit.
    function testFuzz_settle_accountsForEveryUnit(uint96 amount, uint256 returned, uint256 forfeited) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        returned = bound(returned, 0, amount);
        forfeited = bound(forfeited, 0, amount - returned);
        uint256 consumed = amount - returned - forfeited;
        _commit(BID, amount);

        vm.prank(operator);
        escrow.settle(BID, returned, consumed, forfeited);

        assertEq(usdc.balanceOf(bidder), returned);
        assertEq(escrow.revenueOwed(), consumed + forfeited);
        assertEq(usdc.balanceOf(bidder) + usdc.balanceOf(address(escrow)), amount);
    }
}

/// @notice Drives the escrow through random commits, releases, settlements, reclaims and pushes.
contract OffersEscrowHandler is Test {
    TestUSDC3009 internal usdc;
    PatchbayOffersEscrow internal escrow;
    address internal operator;
    address internal bidder;
    uint256 internal bidderKey;

    bytes32[] public open;
    uint256 internal nextBid;

    constructor(TestUSDC3009 usdc_, PatchbayOffersEscrow escrow_, address operator_) {
        usdc = usdc_;
        escrow = escrow_;
        operator = operator_;
        (bidder, bidderKey) = makeAddrAndKey("handler-bidder");
    }

    function commit(uint96 amount) external {
        amount = uint96(bound(amount, 10_000, 1_000_000_000_000));
        bytes32 bidId = keccak256(abi.encode("handler-bid", nextBid++));
        usdc.mint(bidder, amount);
        uint256 validBefore = block.timestamp + 2 minutes;
        bytes32 hash = usdc.digest(bidder, address(escrow), amount, 0, validBefore, bidId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bidderKey, hash);
        vm.prank(operator);
        escrow.commit(bidId, bidder, amount, 0, validBefore, abi.encodePacked(r, s, v));
        open.push(bidId);
    }

    function release(uint256 index) external {
        if (open.length == 0) return;
        bytes32 bidId = _take(index);
        vm.prank(operator);
        escrow.release(bidId);
    }

    function settle(uint256 index, uint256 returned, uint256 forfeited) external {
        if (open.length == 0) return;
        bytes32 bidId = _take(index);
        (, uint96 amount,,) = escrow.commitments(bidId);
        returned = bound(returned, 0, amount);
        forfeited = bound(forfeited, 0, amount - returned);
        vm.prank(operator);
        escrow.settle(bidId, returned, amount - returned - forfeited, forfeited);
    }

    function reclaim(uint256 index) external {
        if (open.length == 0) return;
        bytes32 bidId = _take(index);
        vm.warp(block.timestamp + 14 days);
        escrow.reclaim(bidId);
    }

    function push() external {
        if (escrow.revenueOwed() == 0) return;
        escrow.pushRevenue();
    }

    function _take(uint256 index) internal returns (bytes32 bidId) {
        index = bound(index, 0, open.length - 1);
        bidId = open[index];
        open[index] = open[open.length - 1];
        open.pop();
    }
}

/// @title PatchbayOffersEscrowInvariantTest
/// @notice Whatever order commitments are made and settled in, the escrow always holds exactly the
///         open commitments plus the revenue owed: it can never pay out more than it holds.
contract PatchbayOffersEscrowInvariantTest is StdInvariant, OffersEscrowSetup {
    OffersEscrowHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new OffersEscrowHandler(usdc, escrow, operator);
        targetContract(address(handler));
    }

    function invariant_holdsExactlyTheOpenCommitmentsAndTheRevenueOwed() public view {
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalCommitted() + escrow.revenueOwed());
    }
}
