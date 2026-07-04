// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Freely mintable ERC-20, test-only. Used as the vault's underlying asset, the strategist
/// bond token, and any satellite trade asset in the Foundry test suite. Never deployed to Coston2.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Unrestricted mint — test-only convenience, never deployed to a live network.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
