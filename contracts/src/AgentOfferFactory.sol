// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRegentRevenueStaking} from "./PatchbayEscrow.sol";
import {IAgentOfferMarket} from "./IAgentOfferMarket.sol";
import {AgentOfferMarket} from "./AgentOfferMarket.sol";

/// @title AgentOfferFactory
/// @notice Creates one Offer market per admitted publisher on Base, every one a clone of the same
///         fixed market implementation, paid in Circle's native Base USDC, with the same protocol
///         fee pushed into REGENT revenue staking.
/// @dev The factory deploys the market implementation itself, so the implementation is exactly the
///      `AgentOfferMarket` source this factory was verified with; nobody supplies one. A market's
///      address is a CREATE2 clone salted by its publisher, so `predictMarket` gives it before it
///      exists and it does not move if a block is reorganised.
///
///      The owner only admits and removes publishers. Removing one stops it creating a market; a
///      market already created keeps running, and the owner has no way to touch it or its money.
///      Only a market this factory created (see `MarketCreated` or `marketOf`) is a real one: anyone
///      can clone the public implementation, but such a clone is not listed here.
contract AgentOfferFactory is Ownable2Step {
    /// @notice Circle's native USDC on Base mainnet.
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Base mainnet's chain id. The factory deploys nowhere else.
    uint256 public constant BASE_CHAIN_ID = 8453;

    /// @notice The market implementation every market is a clone of.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable implementation;

    /// @notice The REGENT revenue staking contract every market pushes its protocol fee into.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IRegentRevenueStaking public immutable staking;

    /// @notice The protocol fee every market charges on earned money, in basis points.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable feeBps;

    /// @notice Whether an address may create its market.
    mapping(address publisher => bool) public publisherAllowed;

    /// @notice Each publisher's market, once created.
    mapping(address publisher => address market) public marketOf;

    /// @notice Emitted when the owner admits or removes a publisher, and once at deployment.
    event PublisherAllowed(address indexed publisher, bool allowed);

    /// @notice Emitted when a publisher creates its market.
    event MarketCreated(address indexed publisher, address indexed market, address payout);

    /// @notice Thrown for the wrong chain, missing USDC or staking code, a zero address, a fee
    ///         above the market's `MAX_FEE_BPS`, or a payout wallet that is zero or the market.
    error InvalidConfiguration();

    /// @notice Thrown when an address the owner has not admitted tries to create a market.
    error PublisherNotAllowed();

    /// @notice Thrown when a publisher that already has a market tries to create another.
    error MarketAlreadyExists();

    /// @notice Deploys the factory and the market implementation, and admits Patchbay.
    /// @param admin The owner: admits and removes publishers. Ownable2Step applies to handovers.
    /// @param patchbayPublisher Patchbay's publisher address, admitted from the start.
    /// @param protocolStaking The REGENT revenue staking contract the protocol fee is pushed into.
    /// @param protocolFeeBps The protocol fee, at most `AgentOfferMarket.MAX_FEE_BPS`.
    constructor(address admin, address patchbayPublisher, IRegentRevenueStaking protocolStaking, uint16 protocolFeeBps)
        Ownable(admin)
    {
        if (
            block.chainid != BASE_CHAIN_ID || BASE_USDC.code.length == 0 || patchbayPublisher == address(0)
                || address(protocolStaking).code.length == 0
        ) revert InvalidConfiguration();

        staking = protocolStaking;
        feeBps = protocolFeeBps;
        publisherAllowed[patchbayPublisher] = true;
        emit PublisherAllowed(patchbayPublisher, true);

        AgentOfferMarket market = new AgentOfferMarket();
        if (protocolFeeBps > market.MAX_FEE_BPS()) revert InvalidConfiguration();
        implementation = address(market);
    }

    /// @notice Admits or removes a publisher. Owner only.
    /// @dev Affects only markets not yet created.
    function setPublisherAllowed(address publisher, bool allowed) external onlyOwner {
        if (publisher == address(0)) revert InvalidConfiguration();
        publisherAllowed[publisher] = allowed;

        emit PublisherAllowed(publisher, allowed);
    }

    /// @notice Creates the caller's market, with `payout` as the wallet its earnings are credited
    ///         to for good.
    /// @dev Admitted publishers only, once each. The clone is created and initialized in this one
    ///      call, so nobody can initialize it first.
    /// @param payout The wallet the market credits the publisher's earnings to; not zero and not the
    ///        market. A Safe is a good choice: it can never be changed.
    /// @return market The new market's address, the one `predictMarket` gave.
    function createMarket(address payout) external returns (address market) {
        if (!publisherAllowed[msg.sender]) revert PublisherNotAllowed();
        if (marketOf[msg.sender] != address(0)) revert MarketAlreadyExists();
        if (payout == address(0) || payout == predictMarket(msg.sender)) revert InvalidConfiguration();

        market = Clones.cloneDeterministic(implementation, _salt(msg.sender));
        marketOf[msg.sender] = market;

        // The only step before this is creating the clone, whose creation code calls nothing.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MarketCreated(msg.sender, market, payout);

        IAgentOfferMarket(market)
            .initialize(
                IAgentOfferMarket.Init({
                    usdc: IERC20(BASE_USDC), publisher: msg.sender, payout: payout, staking: staking, feeBps: feeBps
                })
            );
    }

    /// @notice The address `publisher`'s market has, or will have once created.
    function predictMarket(address publisher) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(publisher));
    }

    /// @dev One salt per publisher, so one address per publisher.
    function _salt(address publisher) private pure returns (bytes32) {
        return bytes32(uint256(uint160(publisher)));
    }
}
