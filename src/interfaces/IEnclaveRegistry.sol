// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWeb2Json} from "./IFdcVerification.sol";

/// @title IEnclaveRegistry
/// @notice On-chain root of trust mapping attested TEE enclave signing keys to the vaults they act for.
interface IEnclaveRegistry {
    /// @notice One-time registration of an enclave's signing key for a vault, gated on a valid FDC attestation proof.
    function registerEnclave(address vault, address enclaveSigner, IWeb2Json.Proof calldata proof) external;

    /// @notice Rotates a vault's registered enclave signer to a new key, gated on a fresh valid FDC attestation proof.
    function rotateEnclaveSigner(address vault, address newSigner, IWeb2Json.Proof calldata proof) external;

    /// @notice Returns whether `signer` is the currently trusted enclave signer for `vault`.
    function isValidSigner(address vault, address signer) external view returns (bool);

    /// @notice Returns the currently registered enclave signer for `vault` (address(0) if none/revoked).
    function signerOf(address vault) external view returns (address);
}
