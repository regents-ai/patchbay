// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AgentOfferFactory} from "../src/AgentOfferFactory.sol";
import {AgentOfferMarket} from "../src/AgentOfferMarket.sol";
import {IAgentOfferMarket} from "../src/IAgentOfferMarket.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

/// @notice A six-decimal token standing in for USDC, with Circle's blacklist: a frozen address can
///         neither send nor receive.
contract FreezableUSDC is ERC20 {
    mapping(address account => bool) public frozen;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address account, bool frozen_) external {
        frozen[account] = frozen_;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!frozen[from] && !frozen[to], "FROZEN");
        super._update(from, to, value);
    }
}

/// @notice A hook a token calls on its holder, like an ERC-777 send or receive hook.
interface ITransferHook {
    function onTokenTransfer() external;
}

/// @notice A USDC stand-in that calls its hooked holder back before every transfer out of it and
///         after every transfer into it.
contract HookUSDC is FreezableUSDC {
    address public hooked;

    function hook(address account) external {
        hooked = account;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from == hooked) ITransferHook(from).onTokenTransfer();
        super._update(from, to, value);
        if (to != address(0) && to == hooked) ITransferHook(to).onTokenTransfer();
    }
}

/// @notice Stands in for the REGENT revenue staking contract: pulls the deposit, records its tag
///         and reference, and can be paused.
contract RecordingStaking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    bool public paused;
    bytes32 public lastSourceTag;
    bytes32 public lastSourceRef;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256) {
        require(!paused, "PAUSED");
        lastSourceTag = sourceTag;
        lastSourceRef = sourceRef;
        require(usdc.transferFrom(msg.sender, address(this), amount), "PULL_FAILED");
        return amount;
    }
}

/// @notice A contract wallet (a Safe, say) that approves a hash its owner key signed, until revoked.
contract ContractWallet is IERC1271 {
    address public immutable signer;
    bool public revoked;

    constructor(address signer_) {
        signer = signer_;
    }

    function revoke() external {
        revoked = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (!revoked && err == ECDSA.RecoverError.NoError && recovered == signer) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// @notice Shared deployment, numbers, signing and the books check every suite here uses.
/// @dev The factory only deploys on Base mainnet with code at Circle's USDC address, so every
///      suite sets the chain id to 8453 and places a stand-in token's code at that address.
abstract contract AgentOfferBase is Test {
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint64 internal constant START = 1_800_000_000;
    uint16 internal constant FEE_BPS = 1_000;
    uint16 internal constant CAPACITY = 3;
    uint32 internal constant DURATION = 72 hours;
    uint16 internal constant BUMP_BPS = 1_000;
    /// @dev Five USDC.
    uint128 internal constant FLOOR = 5_000_000;
    bytes32 internal constant SOURCE = keccak256("patchbay.help");
    bytes32 internal constant POLICY = keccak256("patchbay-policy-v1");

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "EligibilityPermit(uint256 placementId,uint16 slot,bytes32 sourceId,address buyer,bytes32 campaignId,bytes32 policyHash,uint128 amountUSDC,uint64 expectedLeaseNonce,uint64 deadline)"
    );

    FreezableUSDC internal usdc;
    RecordingStaking internal staking;
    AgentOfferFactory internal factory;
    AgentOfferMarket internal market;

    address internal admin = makeAddr("admin");
    address internal publisher;
    uint256 internal publisherKey;
    address internal payout = makeAddr("payout");

    /// @dev Chain 8453, a stand-in USDC at Circle's address, the staking stand-in, a factory with a
    ///      10% fee, and Patchbay's market created with its payout wallet.
    function _deploy(FreezableUSDC tokenCode) internal {
        vm.chainId(8453);
        vm.warp(START);
        (publisher, publisherKey) = makeAddrAndKey("publisher");
        vm.etch(BASE_USDC, address(tokenCode).code);
        usdc = FreezableUSDC(BASE_USDC);
        staking = new RecordingStaking(IERC20(BASE_USDC));
        factory = new AgentOfferFactory(admin, publisher, staking, FEE_BPS);
        vm.prank(publisher);
        market = AgentOfferMarket(factory.createMarket(payout));
    }

    function _terms(uint16 capacity, uint32 duration, uint16 bump, uint128 floor)
        internal
        pure
        returns (IAgentOfferMarket.PlacementTerms memory)
    {
        return IAgentOfferMarket.PlacementTerms({
            capacity: capacity, durationSeconds: duration, minBumpBps: bump, floorUSDC: floor, policyHash: POLICY
        });
    }

    /// @dev Patchbay's placement: three slots, 72 hours, 10% step, five USDC floor.
    function _patchbayPlacement(AgentOfferMarket m) internal returns (uint256) {
        vm.prank(m.publisher());
        return m.createPlacement(SOURCE, _terms(CAPACITY, DURATION, BUMP_BPS, FLOOR), "ipfs://placement");
    }

    function _campaign(address buyer) internal pure returns (bytes32) {
        return keccak256(abi.encode("campaign", buyer));
    }

    /// @dev A purchase of `slot` at the slot's current nonce, valid for an hour.
    function _purchase(AgentOfferMarket m, address buyer, uint256 placementId, uint16 slot, uint256 amount)
        internal
        view
        returns (IAgentOfferMarket.Purchase memory)
    {
        return IAgentOfferMarket.Purchase({
            placementId: placementId,
            slot: slot,
            campaignId: _campaign(buyer),
            amountUSDC: SafeCast.toUint128(amount),
            expectedLeaseNonce: m.getLease(placementId, slot).nonce,
            deadline: SafeCast.toUint64(vm.getBlockTimestamp() + 1 hours)
        });
    }

    /// @dev The admission digest, built here from the EIP-712 rules rather than read from the
    ///      market, so a mistake in the market's own hashing shows up as a failed purchase.
    function _digest(AgentOfferMarket m, IAgentOfferMarket.Purchase memory p, address buyer)
        internal
        view
        returns (bytes32)
    {
        IAgentOfferMarket.Placement memory placement = m.getPlacement(p.placementId);
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("AgentOfferMarket"), keccak256("1"), block.chainid, address(m))
        );
        bytes memory head = abi.encode(PERMIT_TYPEHASH, p.placementId, p.slot, placement.sourceId, buyer);
        bytes memory tail =
            abi.encode(p.campaignId, placement.terms.policyHash, p.amountUSDC, p.expectedLeaseNonce, p.deadline);
        return keccak256(abi.encodePacked("\x19\x01", domain, keccak256(bytes.concat(head, tail))));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The publisher's admission of `buyer`'s purchase on market `m`.
    function _permit(AgentOfferMarket m, IAgentOfferMarket.Purchase memory p, address buyer)
        internal
        view
        returns (bytes memory)
    {
        return _sign(publisherKey, _digest(m, p, buyer));
    }

    function _fund(AgentOfferMarket m, address buyer, uint256 amount) internal {
        usdc.mint(buyer, amount);
        vm.prank(buyer);
        usdc.approve(address(m), amount);
    }

    /// @dev Funds, admits and makes a purchase for `buyer`.
    function _buy(AgentOfferMarket m, address buyer, uint256 placementId, uint16 slot, uint256 amount)
        internal
        returns (IAgentOfferMarket.Purchase memory p)
    {
        p = _purchase(m, buyer, placementId, slot, amount);
        bytes memory permit = _permit(m, p, buyer);
        _fund(m, buyer, amount);
        vm.prank(buyer);
        m.buy(p, permit);
    }

    /// @dev Every unit the market holds backs an unsettled lease, a credit or revenue owed, and
    ///      nothing else: no USDC is sent to the market directly in these suites.
    function _assertBooks(AgentOfferMarket m) internal view {
        assertEq(usdc.balanceOf(address(m)), m.totalLeaseDeposits() + m.totalClaimable() + m.revenueOwed(), "books");
    }
}
