// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnclaveRegistry} from "../src/core/EnclaveRegistry.sol";
import {IWeb2Json} from "../src/interfaces/IFdcVerification.sol";

/// @notice One-time (per vault) on-chain registration of a live enclave's attested signing key, run
/// once the TEE has actually booted, attested via Google Confidential Space, and the relayer has
/// obtained a Web2Json attestation proof from the Flare Data Connector.
///
/// `FDC_ATTESTATION_PROOF` must be the ABI-encoding of an `IWeb2Json.Proof` struct
/// (`abi.encode(proof)`), as produced by the relayer after it retrieves the FDC's Merkle proof for
/// the attestation request.
///
/// Usage:
///   forge script script/RegisterEnclave.s.sol:RegisterEnclave --rpc-url coston2 --broadcast
contract RegisterEnclave is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("ENCLAVE_REGISTRY_ADDRESS");
        address vaultAddress = vm.envAddress("ALPHA_VAULT_ADDRESS");
        address enclaveSigner = vm.envAddress("ENCLAVE_SIGNER_ADDRESS");
        bytes memory proofBytes = vm.envBytes("FDC_ATTESTATION_PROOF");

        IWeb2Json.Proof memory proof = abi.decode(proofBytes, (IWeb2Json.Proof));

        vm.startBroadcast(deployerKey);
        EnclaveRegistry(registryAddress).registerEnclave(vaultAddress, enclaveSigner, proof);
        vm.stopBroadcast();

        console.log("Registered enclave signer", enclaveSigner, "for vault", vaultAddress);
    }
}
