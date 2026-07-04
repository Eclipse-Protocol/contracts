// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockDexRouter
/// @notice Deterministic swap simulator for testing AlphaVault without a real DEX. Exchange rates
/// between two tokens are configurable per-pair (1e18-scaled); output tokens are minted directly to
/// the recipient (assumes both tokens are {MockERC20}), so the router never needs pre-funding.
/// Test-only, never deployed to Coston2.
contract MockDexRouter is IDexRouter {
    using SafeERC20 for IERC20;

    /// @notice rate[tokenIn][tokenOut] = amount of tokenOut per 1e18 tokenIn, in 1e18 fixed point.
    mapping(address tokenIn => mapping(address tokenOut => uint256 rate)) public rateOf;

    error RateNotSet(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMin);
    error DeadlineExpired(uint256 deadline, uint256 blockTimestamp);

    /// @notice Sets the exchange rate for both directions of a pair (`rateAtoB` and its reciprocal are
    /// independent — set both explicitly so tests can model spreads/slippage precisely).
    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rateOf[tokenIn][tokenOut] = rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 rate = rateOf[tokenIn][tokenOut];
        if (rate == 0) revert RateNotSet(tokenIn, tokenOut);

        uint256 amountOut = (amountIn * rate) / 1e18;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 rate = rateOf[tokenIn][tokenOut];
        if (rate == 0) revert RateNotSet(tokenIn, tokenOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = (amountIn * rate) / 1e18;
    }
}
