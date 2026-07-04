// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IWeb2Json
/// @notice Struct definitions for Flare Data Connector's "Web2Json" attestation type (formerly
/// referred to as "JsonApi" in older Flare documentation), mirrored from Flare's official periphery
/// package (flare-foundation/flare-foundry-periphery-package, src/coston2/IWeb2Json.sol).
/// This attestation type lets an off-chain relayer fetch JSON from an arbitrary URL, apply a jq
/// post-processing filter, and have the FDC's decentralized attestation providers independently
/// re-fetch, verify, and Merkle-commit the resulting ABI-encoded data on-chain. Eclipse uses this
/// to bring a Google Confidential Space attestation verification result on-chain.
interface IWeb2Json {
    struct RequestBody {
        string url;
        string httpMethod;
        string headers;
        string queryParams;
        string body;
        string postProcessJq;
        string abiSignature;
    }

    struct ResponseBody {
        bytes abiEncodedData;
    }

    struct Response {
        bytes32 attestationType;
        bytes32 sourceId;
        uint64 votingRound;
        uint64 lowestUsedTimestamp;
        RequestBody requestBody;
        ResponseBody responseBody;
    }

    struct Proof {
        bytes32[] merkleProof;
        Response data;
    }
}

/// @title IFdcVerification
/// @notice Minimal interface over Flare's FDC verification contract, exposing only the Web2Json
/// verification entrypoint EnclaveRegistry relies on. The real periphery package's `IFdcVerification`
/// aggregates many more attestation-type verifiers (payment, address validity, EVM transaction, etc.)
/// that Eclipse does not use.
interface IFdcVerification {
    /// @notice Verifies a Web2Json attestation proof against the FDC's most recent Merkle root.
    /// @param _proof The proof (Merkle path + attested response data) produced by the FDC.
    /// @return _proved True if the proof is valid and consistent with a finalized FDC voting round.
    function verifyWeb2Json(IWeb2Json.Proof calldata _proof) external view returns (bool _proved);
}
