// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnclaveRegistry} from "../src/core/EnclaveRegistry.sol";
import {IWeb2Json} from "../src/interfaces/IFdcVerification.sol";

/// @notice Rotates a vault's already-registered enclave signing key to a new one, anchored in a
/// fresh FDC Web2Json attestation proof. Used instead of RegisterEnclave.s.sol when a signer is
/// already on file for the vault (registerEnclave reverts with AlreadyRegistered in that case).
///
/// `FDC_ATTESTATION_PROOF` must be the ABI-encoding of an `IWeb2Json.Proof` struct
/// (`abi.encode(proof)`) for the NEW signer, as produced by the relayer/submitFdc.ts flow.
///
/// Usage:
///   forge script script/RotateEnclaveSigner.s.sol:RotateEnclaveSigner --rpc-url coston2 --broadcast
contract RotateEnclaveSigner is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("ENCLAVE_REGISTRY_ADDRESS");
        address vaultAddress = vm.envAddress("ALPHA_VAULT_ADDRESS");
        address newSigner = vm.envAddress("ENCLAVE_SIGNER_ADDRESS");
        bytes memory proofBytes = vm.envBytes("FDC_ATTESTATION_PROOF");

        IWeb2Json.Proof memory proof = abi.decode(proofBytes, (IWeb2Json.Proof));

        vm.startBroadcast(deployerKey);
        EnclaveRegistry(registryAddress).rotateEnclaveSigner(vaultAddress, newSigner, proof);
        vm.stopBroadcast();

        console.log("Rotated enclave signer to", newSigner, "for vault", vaultAddress);
    }
}
