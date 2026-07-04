// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title PerformanceLedger
/// @notice Append-only, hash-chained record of a vault's per-epoch NAV, deployed independently of
/// AlphaVault so the audit trail survives any future vault upgrade or migration.
/// @dev Each entry commits `keccak256(abi.encode(previousHash, nav, timestamp))`, so any retroactive
/// edit to historical data breaks the chain and is publicly detectable via {verifyChain}.
contract PerformanceLedger is Ownable2Step {
    struct Epoch {
        uint256 nav;
        uint256 timestamp;
        bytes32 hash;
    }

    /// @notice Hash chain root before the first epoch is committed.
    bytes32 public constant GENESIS_HASH = bytes32(0);

    /// @notice The AlphaVault permitted to commit epochs, set once by the owner post-deployment.
    address public vault;

    /// @notice Whether {vault} has already been bound (registration is one-time).
    bool public vaultSet;

    Epoch[] private _epochs;

    event VaultSet(address indexed vault);
    event EpochCommitted(uint256 indexed epochIndex, uint256 nav, uint256 timestamp, bytes32 hash);

    error VaultAlreadySet();
    error NotVault();
    error EpochOutOfRange(uint256 index, uint256 length);

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @notice One-time binding of the AlphaVault allowed to call {commitEpoch}.
    /// @dev Deliberately one-time and owner-gated: the ledger's integrity guarantee depends on epochs
    /// only ever being committed by a single known vault, not an admin-swappable one.
    function setVault(address _vault) external onlyOwner {
        if (vaultSet) revert VaultAlreadySet();
        vault = _vault;
        vaultSet = true;
        emit VaultSet(_vault);
    }

    /// @notice Appends a new epoch to the hash chain. Callable only by the bound vault.
    /// @return newHash The hash committed for this epoch.
    function commitEpoch(uint256 nav, uint256 timestamp) external onlyVault returns (bytes32 newHash) {
        bytes32 prevHash = _epochs.length == 0 ? GENESIS_HASH : _epochs[_epochs.length - 1].hash;
        newHash = keccak256(abi.encode(prevHash, nav, timestamp));
        _epochs.push(Epoch({nav: nav, timestamp: timestamp, hash: newHash}));
        emit EpochCommitted(_epochs.length - 1, nav, timestamp, newHash);
    }

    /// @notice Total number of committed epochs.
    function epochCount() external view returns (uint256) {
        return _epochs.length;
    }

    /// @notice Returns a single epoch by index.
    function getEpoch(uint256 index) external view returns (Epoch memory) {
        if (index >= _epochs.length) revert EpochOutOfRange(index, _epochs.length);
        return _epochs[index];
    }

    /// @notice Returns a paginated slice of epochs, for the frontend's ledger explorer view.
    /// @param offset Starting index (inclusive).
    /// @param limit Maximum number of epochs to return.
    function getEpochs(uint256 offset, uint256 limit) external view returns (Epoch[] memory page) {
        uint256 length = _epochs.length;
        if (offset >= length) {
            return new Epoch[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        page = new Epoch[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _epochs[i];
        }
    }

    /// @notice Recomputes the full hash chain from stored epoch data and verifies it is unbroken.
    /// @return valid True if every stored hash matches its recomputed value given the prior hash.
    function verifyChain() external view returns (bool valid) {
        bytes32 prevHash = GENESIS_HASH;
        uint256 length = _epochs.length;
        for (uint256 i = 0; i < length; i++) {
            Epoch storage e = _epochs[i];
            bytes32 expected = keccak256(abi.encode(prevHash, e.nav, e.timestamp));
            if (expected != e.hash) {
                return false;
            }
            prevHash = e.hash;
        }
        return true;
    }
}
