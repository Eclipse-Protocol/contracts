// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IEnclaveRegistry} from "../interfaces/IEnclaveRegistry.sol";
import {IFdcVerification, IWeb2Json} from "../interfaces/IFdcVerification.sol";

/// @title EnclaveRegistry
/// @notice The on-chain root of trust for enclave attestation. Stores, per vault, the currently
/// trusted enclave signing key, anchored in a Flare Data Connector (FDC) Web2Json attestation proof
/// rather than in any admin's say-so.
/// @dev Registration and rotation are both permissionless and proof-gated: anyone may submit a valid
/// FDC proof binding a (vault, signer) pair, and it is the proof itself — not `msg.sender` — that is
/// trusted. The one exception is {emergencyRevoke}, a deliberately separate, owner-gated escape hatch
/// for handling a compromised key faster than a full re-attestation cycle (documented MVP tradeoff).
contract EnclaveRegistry is IEnclaveRegistry, Ownable2Step {
    /// @notice The FDC verification contract used to validate attestation proofs.
    IFdcVerification public immutable fdcVerification;

    mapping(address vault => address signer) private _signerOf;

    event EnclaveRegistered(address indexed vault, address indexed signer);
    event EnclaveRotated(address indexed vault, address indexed oldSigner, address indexed newSigner);
    event EnclaveEmergencyRevoked(address indexed vault, address indexed revokedSigner);

    error AlreadyRegistered(address vault);
    error NotRegistered(address vault);
    error InvalidAttestationProof();
    error AttestationMismatch();

    constructor(address initialOwner, IFdcVerification _fdcVerification) Ownable(initialOwner) {
        fdcVerification = _fdcVerification;
    }

    /// @inheritdoc IEnclaveRegistry
    function registerEnclave(address vault, address enclaveSigner, IWeb2Json.Proof calldata proof) external {
        if (_signerOf[vault] != address(0)) revert AlreadyRegistered(vault);
        _verifyAndSet(vault, enclaveSigner, proof);
        emit EnclaveRegistered(vault, enclaveSigner);
    }

    /// @inheritdoc IEnclaveRegistry
    function rotateEnclaveSigner(address vault, address newSigner, IWeb2Json.Proof calldata proof) external {
        address oldSigner = _signerOf[vault];
        if (oldSigner == address(0)) revert NotRegistered(vault);
        _verifyAndSet(vault, newSigner, proof);
        emit EnclaveRotated(vault, oldSigner, newSigner);
    }

    /// @notice Emergency admin override that immediately blanks a vault's trusted signer, e.g. on a
    /// suspected key compromise, without waiting for a fresh attestation. Distinct from
    /// {rotateEnclaveSigner} on purpose: this is the one place trust is anchored in the owner, not proof.
    function emergencyRevoke(address vault) external onlyOwner {
        address oldSigner = _signerOf[vault];
        if (oldSigner == address(0)) revert NotRegistered(vault);
        delete _signerOf[vault];
        emit EnclaveEmergencyRevoked(vault, oldSigner);
    }

    /// @inheritdoc IEnclaveRegistry
    function isValidSigner(address vault, address signer) external view returns (bool) {
        return signer != address(0) && _signerOf[vault] == signer;
    }

    /// @inheritdoc IEnclaveRegistry
    function signerOf(address vault) external view returns (address) {
        return _signerOf[vault];
    }

    function _verifyAndSet(address vault, address signer, IWeb2Json.Proof calldata proof) private {
        if (!fdcVerification.verifyWeb2Json(proof)) revert InvalidAttestationProof();

        (address attestedVault, address attestedSigner) =
            abi.decode(proof.data.responseBody.abiEncodedData, (address, address));
        if (attestedVault != vault || attestedSigner != signer) revert AttestationMismatch();

        _signerOf[vault] = signer;
    }
}
