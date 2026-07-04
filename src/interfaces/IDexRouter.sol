// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDexRouter
/// @notice Minimal Uniswap-V2-style router interface, matching the `swapExactTokensForTokens`
/// shape exposed by Flare-native DEX routers (e.g. SparkDEX's UniswapV2Router02 deployment on
/// Coston2/Flare). AlphaVault is decoupled from any single router implementation via this interface.
interface IDexRouter {
    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible along `path`.
    /// @param amountIn The exact amount of input tokens to send.
    /// @param amountOutMin The minimum amount of output tokens that must be received, or the call reverts.
    /// @param path An array of token addresses; `path[0]` is the input token, `path[path.length - 1]` is the output token.
    /// @param to The recipient address of the output tokens.
    /// @param deadline Unix timestamp after which the transaction will revert.
    /// @return amounts The input token amount and all subsequent output token amounts along `path`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Given an input amount and a path, returns the resulting output amounts (view-only preview).
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}
