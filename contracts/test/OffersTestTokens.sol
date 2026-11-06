// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRegentRevenueStaking} from "../src/RegentOffers.sol";

/// @notice Stands in for USDC v2.2 as RegentOffers uses it: six decimals, approve then
///         `transferFrom`, and addresses that may not send or receive USDC. It can be made to
///         deliver less than a `transferFrom` asks for, as a changed token would.
contract OffersTestUSDC is ERC20 {
    mapping(address => bool) public blocked;
    uint256 public shortBy;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool blocked_) external {
        blocked[account] = blocked_;
    }

    /// @notice Makes the next `transferFrom` calls deliver `shortBy_` less than asked.
    function setShortBy(uint256 shortBy_) external {
        shortBy = shortBy_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value - shortBy);
        return true;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!blocked[from] && !blocked[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}

/// @notice Stands in for the REGENT revenue staking contract: pulls the deposit, can be paused,
///         and can be made to pull short.
contract OffersTestStaking is IRegentRevenueStaking {
    IERC20 internal immutable usdc;
    bool public paused;
    uint256 public shortBy;
    bytes32 public lastSourceTag;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    /// @notice Makes the next deposits pull `shortBy_` less than asked, as a faulty contract would.
    function setShortBy(uint256 shortBy_) external {
        shortBy = shortBy_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32) external returns (uint256) {
        require(!paused, "PAUSED");
        lastSourceTag = sourceTag;
        require(usdc.transferFrom(msg.sender, address(this), amount - shortBy), "PULL_FAILED");
        return amount;
    }
}

/// @notice A minimal contract account: its owner has it call anything.
contract OffersTestAccount {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address to, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "NOT_OWNER");
        (bool ok, bytes memory answer) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
        return answer;
    }
}
