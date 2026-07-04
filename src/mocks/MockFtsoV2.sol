// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFtsoV2} from "../interfaces/IFtsoV2.sol";

/// @title MockFtsoV2
/// @notice Configurable, settable price feed for testing AlphaVault's NAV valuation logic without a
/// live FTSOv2 deployment. Test-only, never deployed to Coston2.
contract MockFtsoV2 is IFtsoV2 {
    struct Feed {
        uint256 value;
        uint64 timestamp;
    }

    mapping(bytes21 feedId => Feed feed) public feeds;

    /// @notice Sets the value (18-decimal, "in wei") and timestamp for a feed id.
    function setPrice(bytes21 feedId, uint256 value, uint64 timestamp) external {
        feeds[feedId] = Feed({value: value, timestamp: timestamp});
    }

    function getFeedByIdInWei(bytes21 _feedId) external payable returns (uint256 _value, uint64 _timestamp) {
        Feed memory feed = feeds[_feedId];
        return (feed.value, feed.timestamp);
    }

    function calculateFeeById(bytes21) external pure returns (uint256 _fee) {
        return 0;
    }
}
