// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFdcVerification, IWeb2Json} from "../interfaces/IFdcVerification.sol";

/// @title MockFdcVerification
/// @notice Test double for Flare's FDC verification contract. Returns a settable boolean result so
/// both the successful and rejected enclave-registration paths can be exercised, and provides a
/// helper to build a well-formed proof encoding a (vault, signer) binding. Test-only, never deployed
/// to Coston2.
contract MockFdcVerification is IFdcVerification {
    bool public nextResult = true;

    /// @notice Configures whether the next (and subsequent) calls to {verifyWeb2Json} succeed.
    function setNextResult(bool result) external {
        nextResult = result;
    }

    function verifyWeb2Json(
        IWeb2Json.Proof calldata
    ) external view returns (bool _proved) {
        return nextResult;
    }

    /// @notice Builds a proof whose attested response body ABI-encodes `(vault, signer)`, matching
    /// what EnclaveRegistry expects to decode from a real Web2Json attestation response.
    function buildProof(
        address vault,
        address signer
    ) external view returns (IWeb2Json.Proof memory proof) {
        IWeb2Json.ResponseBody memory responseBody = IWeb2Json.ResponseBody({
            abiEncodedData: abi.encode(vault, signer)
        });

        IWeb2Json.RequestBody memory requestBody = IWeb2Json.RequestBody({
            url: "",
            httpMethod: "GET",
            headers: "{}",
            queryParams: "{}",
            body: "{}",
            postProcessJq: ".",
            abiSignature: "(address,address)"
        });

        IWeb2Json.Response memory response = IWeb2Json.Response({
            attestationType: bytes32("Web2Json"),
            sourceId: bytes32("PRIVATE"),
            votingRound: 0,
            lowestUsedTimestamp: uint64(block.timestamp),
            requestBody: requestBody,
            responseBody: responseBody
        });

        proof = IWeb2Json.Proof({
            merkleProof: new bytes32[](0),
            data: response
        });
    }
}
