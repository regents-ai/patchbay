// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRegentRevenueStaking} from "../src/PatchbayEscrow.sol";

// The two stand-ins the offers lab places on its own chain on this machine
// (`platform/dev/patchbay_dev/offers_lab.ex`). Never deployed anywhere else.

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
