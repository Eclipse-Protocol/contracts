// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IAlphaVault
/// @notice External interface for the Eclipse Protocol ERC-4626 alpha vault.
interface IAlphaVault is IERC4626 {
    enum TradeDirection {
        Buy, // spend underlying `asset()` to acquire `TradeInstruction.asset`
        Sell // spend `TradeInstruction.asset` to acquire back the underlying `asset()`

    }

    /// @notice An enclave-signed trade instruction. Signed as EIP-712 typed data by the registered enclave key.
    /// @param asset The non-underlying counter-asset being traded against the vault's underlying asset.
    /// @param direction Whether the vault is buying `asset` with its underlying, or selling `asset` back to it.
    /// @param size The amount of the input token (underlying if Buy, `asset` if Sell) to swap.
    /// @param minAmountOut The minimum amount of output token acceptable, enforced on-chain as slippage protection.
    /// @param nonce A per-vault unique value preventing instruction replay.
    /// @param deadline Unix timestamp after which the instruction can no longer be submitted.
    struct TradeInstruction {
        address asset;
        TradeDirection direction;
        uint256 size;
        uint256 minAmountOut;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Verifies, executes, and settles an enclave-signed trade instruction in a single atomic transaction.
    function submitInstruction(TradeInstruction calldata instruction, bytes calldata signature) external;

    /// @notice Permissionless, idempotent performance-fee harvest against the global high-water mark.
    function harvest() external;
}
