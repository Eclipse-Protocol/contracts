// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EnclaveRegistry} from "../../src/core/EnclaveRegistry.sol";
import {MockFdcVerification} from "../../src/mocks/MockFdcVerification.sol";
import {IWeb2Json, IFdcVerification} from "../../src/interfaces/IFdcVerification.sol";

contract EnclaveRegistryTest is Test {
    EnclaveRegistry internal registry;
    MockFdcVerification internal fdc;

    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal signerA = makeAddr("signerA");
    address internal signerB = makeAddr("signerB");

    function setUp() public {
        fdc = new MockFdcVerification();
        registry = new EnclaveRegistry(owner, IFdcVerification(address(fdc)));
    }

    function test_registerEnclave_succeedsWithValidProof() public {
        IWeb2Json.Proof memory proof = fdc.buildProof(vault, signerA);

        registry.registerEnclave(vault, signerA, proof);

        assertEq(registry.signerOf(vault), signerA);
        assertTrue(registry.isValidSigner(vault, signerA));
        assertFalse(registry.isValidSigner(vault, signerB));
    }

    function test_registerEnclave_revertsOnInvalidProof() public {
        fdc.setNextResult(false);
        IWeb2Json.Proof memory proof = fdc.buildProof(vault, signerA);

        vm.expectRevert(EnclaveRegistry.InvalidAttestationProof.selector);
        registry.registerEnclave(vault, signerA, proof);

        assertEq(registry.signerOf(vault), address(0));
    }

    function test_registerEnclave_revertsOnMismatchedBinding() public {
        // Proof commits to a different vault/signer pair than what's being registered.
        IWeb2Json.Proof memory proof = fdc.buildProof(vault, signerA);
        address otherVault = makeAddr("otherVault");

        vm.expectRevert(EnclaveRegistry.AttestationMismatch.selector);
        registry.registerEnclave(otherVault, signerA, proof);
    }

    function test_registerEnclave_revertsIfAlreadyRegistered() public {
        IWeb2Json.Proof memory proof = fdc.buildProof(vault, signerA);
        registry.registerEnclave(vault, signerA, proof);

        vm.expectRevert(abi.encodeWithSelector(EnclaveRegistry.AlreadyRegistered.selector, vault));
        registry.registerEnclave(vault, signerA, proof);
    }

    function test_isValidSigner_falseForUnregisteredVault() public view {
        assertFalse(registry.isValidSigner(vault, signerA));
    }

    function test_rotateEnclaveSigner_succeedsWithFreshProof() public {
        IWeb2Json.Proof memory proof1 = fdc.buildProof(vault, signerA);
        registry.registerEnclave(vault, signerA, proof1);

        IWeb2Json.Proof memory proof2 = fdc.buildProof(vault, signerB);
        registry.rotateEnclaveSigner(vault, signerB, proof2);

        assertEq(registry.signerOf(vault), signerB);
        assertFalse(registry.isValidSigner(vault, signerA));
        assertTrue(registry.isValidSigner(vault, signerB));
    }

    function test_rotateEnclaveSigner_revertsIfNotYetRegistered() public {
        IWeb2Json.Proof memory proof = fdc.buildProof(vault, signerA);
        vm.expectRevert(abi.encodeWithSelector(EnclaveRegistry.NotRegistered.selector, vault));
        registry.rotateEnclaveSigner(vault, signerA, proof);
    }

    function test_rotateEnclaveSigner_isPermissionless() public {
        // Trust is anchored in the proof, not the caller — any address may submit a valid rotation.
        IWeb2Json.Proof memory proof1 = fdc.buildProof(vault, signerA);
        registry.registerEnclave(vault, signerA, proof1);

        IWeb2Json.Proof memory proof2 = fdc.buildProof(vault, signerB);
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        registry.rotateEnclaveSigner(vault, signerB, proof2);

        assertEq(registry.signerOf(vault), signerB);
    }

    function test_emergencyRevoke_onlyOwner() public {
        IWeb2Json.Proof memory proof = fdc.buildProof(vault, signerA);
        registry.registerEnclave(vault, signerA, proof);

        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomCaller));
        registry.emergencyRevoke(vault);

        vm.prank(owner);
        registry.emergencyRevoke(vault);

        assertEq(registry.signerOf(vault), address(0));
        assertFalse(registry.isValidSigner(vault, signerA));
    }

    function test_emergencyRevoke_revertsIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EnclaveRegistry.NotRegistered.selector, vault));
        registry.emergencyRevoke(vault);
    }
}
