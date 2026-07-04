// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StrategyRegistry
/// @notice Strategist-facing registry and bonding contract. Listing is free — this contract exists
/// purely for strategy discovery bookkeeping and the economic slashing backstop described in the
/// protocol's trust model, not fee collection.
contract StrategyRegistry is Ownable2Step {
    using SafeERC20 for IERC20;

    struct Strategy {
        string name;
        address vault;
        address strategist;
        uint256 bondAmount;
    }

    /// @notice The single ERC-20 stake token bonded by all strategists on this registry.
    IERC20 public immutable bondToken;

    Strategy[] private _strategies;

    /// @notice 1-based index into {_strategies} for a given vault; 0 means "not registered".
    mapping(address vault => uint256 indexPlusOne) private _strategyIndexOf;

    event StrategyRegistered(address indexed vault, address indexed strategist, string name, uint256 bondAmount);
    event StrategySlashed(address indexed vault, uint256 amount, string reason);

    error VaultAlreadyRegistered(address vault);
    error VaultNotRegistered(address vault);
    error InsufficientBond(uint256 available, uint256 requested);

    constructor(address initialOwner, IERC20 _bondToken) Ownable(initialOwner) {
        bondToken = _bondToken;
    }

    /// @notice Registers a new strategy/vault and pulls its strategist bond from the caller.
    /// @dev Free to list — the only cost is the bond itself, which is slashable, not a protocol fee.
    function registerStrategy(address vault, string calldata name, address strategist, uint256 bondAmount) external {
        if (_strategyIndexOf[vault] != 0) revert VaultAlreadyRegistered(vault);

        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        _strategies.push(Strategy({name: name, vault: vault, strategist: strategist, bondAmount: bondAmount}));
        _strategyIndexOf[vault] = _strategies.length;

        emit StrategyRegistered(vault, strategist, name, bondAmount);
    }

    /// @notice Reduces a strategist's bond, e.g. when EnclaveRegistry evidence shows an unauthorized
    /// key rotation attempt. Owner-gated for the MVP; a decentralized dispute mechanism is post-hackathon
    /// roadmap, not solved here.
    function slash(address vault, uint256 amount, string calldata reason) external onlyOwner {
        uint256 index = _strategyIndexOf[vault];
        if (index == 0) revert VaultNotRegistered(vault);

        Strategy storage strategy = _strategies[index - 1];
        if (amount > strategy.bondAmount) revert InsufficientBond(strategy.bondAmount, amount);

        strategy.bondAmount -= amount;
        emit StrategySlashed(vault, amount, reason);
    }

    /// @notice Total number of registered strategies.
    function strategyCount() external view returns (uint256) {
        return _strategies.length;
    }

    /// @notice Returns a strategy by its position in the registry (for marketplace listing/pagination).
    function getStrategy(uint256 index) external view returns (Strategy memory) {
        return _strategies[index];
    }

    /// @notice Returns the strategy registered for a given vault.
    function getStrategyByVault(address vault) external view returns (Strategy memory) {
        uint256 index = _strategyIndexOf[vault];
        if (index == 0) revert VaultNotRegistered(vault);
        return _strategies[index - 1];
    }

    /// @notice Returns whether a vault has a registered strategy.
    function isRegistered(address vault) external view returns (bool) {
        return _strategyIndexOf[vault] != 0;
    }
}
