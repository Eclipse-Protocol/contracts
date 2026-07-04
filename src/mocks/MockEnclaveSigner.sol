// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @title MockEnclaveSigner
/// @notice Test helper that signs arbitrary digests with a known test private key, simulating the
/// enclave's EIP-712 signing behavior so Foundry tests can produce validly-signed trade instructions.
/// Relies on forge-std's `Vm.sign` cheatcode, which is only available in a `forge test`/`forge script`
/// EVM — this contract is test-only and is never deployed to Coston2.
contract MockEnclaveSigner {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The enclave's test private key.
    uint256 public immutable enclavePrivateKey;

    /// @notice The address derived from {enclavePrivateKey} — register this as the trusted signer.
    address public immutable enclaveAddress;

    constructor(uint256 privateKey) {
        enclavePrivateKey = privateKey;
        enclaveAddress = vm.addr(privateKey);
    }

    /// @notice Signs an EIP-712 digest (e.g. produced by `AlphaVault.hashTradeInstruction`) and returns
    /// a 65-byte `(r, s, v)` signature in the standard packed layout.
    function sign(bytes32 digest) external view returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(enclavePrivateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
