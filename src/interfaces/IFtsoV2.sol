// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFtsoV2
/// @notice Minimal interface over Flare's enshrined FTSOv2 price feed contract, mirroring the
/// function shapes of the official `FtsoV2Interface` published in Flare's periphery package
/// (flare-foundation/flare-foundry-periphery-package, src/coston2/FtsoV2Interface.sol).
/// Only the subset of functions AlphaVault relies on for NAV valuation is declared here; the
/// real periphery package exposes additional batch/proof-verification functions.
/// @dev Feed ids are `bytes21` identifiers assigned by Flare (e.g. FLR/USD, C2FLR/USD). Reads are
/// `payable` because some feeds on mainnet may charge a small anti-spam fee (see `calculateFeeById`);
/// on Coston2 this fee is currently zero for supported feeds.
interface IFtsoV2 {
    /// @notice Returns the value of a feed, scaled to 18 decimals ("in wei"), and the timestamp it was last updated.
    /// @param _feedId The Flare feed id (e.g. keccak-derived category + symbol byte string).
    /// @return _value The feed value scaled to 18 decimals.
    /// @return _timestamp The unix timestamp of the voting round the value was finalized in.
    function getFeedByIdInWei(bytes21 _feedId) external payable returns (uint256 _value, uint64 _timestamp);

    /// @notice Returns the fee (in native gas token wei) required to read a given feed.
    function calculateFeeById(bytes21 _feedId) external view returns (uint256 _fee);
}
