// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FeeMath
/// @notice Pure, stateless price-per-share / high-water-mark fee math for AlphaVault. Isolated from
/// vault storage so it is independently unit- and fuzz-testable and reusable across vault types.
/// @dev Assumes both the vault's underlying asset and its ERC-4626 shares use 18 decimals, so a
/// price-per-share of `1e18` represents a 1:1 NAV — this mirrors the spec's own convention of
/// seeding the genesis high-water mark at `1.20e18`. A generalized version supporting arbitrary
/// underlying decimals is out of scope for this MVP (see README "MVP tradeoffs").
library FeeMath {
    /// @notice Fixed-point scale used for price-per-share values (1e18 = 1:1 NAV).
    uint256 internal constant WAD = 1e18;

    /// @notice Basis-point denominator (100.00%).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Total performance fee taken on new profit above the high-water mark: 10%.
    uint256 internal constant PERFORMANCE_FEE_BPS = 1_000;

    /// @notice Share of gross profit minted to the protocol treasury: 3%.
    uint256 internal constant TREASURY_FEE_BPS = 300;

    /// @notice Share of gross profit minted to the strategist: 7%.
    uint256 internal constant STRATEGIST_FEE_BPS = 700;

    /// @notice Computes the current price-per-share, in WAD (1e18) fixed point.
    /// @dev Returns `WAD` (1:1) for an empty vault, matching the genesis convention.
    function pricePerShare(uint256 totalAssets_, uint256 totalSupply_) internal pure returns (uint256) {
        if (totalSupply_ == 0) {
            return WAD;
        }
        return (totalAssets_ * WAD) / totalSupply_;
    }

    /// @notice Computes the treasury and strategist shares to mint for a harvest, given a price-per-share
    /// snapshot. Returns `(0, 0)` if `currentPPS` has not set a new all-time high above `highWaterMark`.
    /// @dev Shares are computed from a single combined fee-value dilution formula
    /// (`shares = feeValue * totalSupply / (totalAssets - feeValue)`) and then split 3:7, rather than
    /// computing each recipient's shares independently against a shifting totalSupply — this avoids the
    /// second mint being valued against a supply already diluted by the first.
    function computeFeeShares(
        uint256 currentPPS,
        uint256 highWaterMark,
        uint256 totalAssets_,
        uint256 totalSupply_
    ) internal pure returns (uint256 treasuryShares, uint256 strategistShares) {
        if (currentPPS <= highWaterMark || totalSupply_ == 0) {
            return (0, 0);
        }

        uint256 gainPerShare = currentPPS - highWaterMark;
        uint256 totalGainValue = (gainPerShare * totalSupply_) / WAD;
        uint256 feeValue = (totalGainValue * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
        if (feeValue == 0 || feeValue >= totalAssets_) {
            return (0, 0);
        }

        uint256 combinedShares = (feeValue * totalSupply_) / (totalAssets_ - feeValue);
        if (combinedShares == 0) {
            return (0, 0);
        }

        treasuryShares = (combinedShares * TREASURY_FEE_BPS) / PERFORMANCE_FEE_BPS;
        strategistShares = combinedShares - treasuryShares;
    }
}
