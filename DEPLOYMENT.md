# Eclipse Protocol — Deployment & Live Status

Coston2 testnet (chain id `114`). Last updated 2026-07-16 (Week 2, Day 5).

## Deployed contracts

| Contract | Address |
|---|---|
| `AlphaVault` | `0x1b0cf88974ffBC1Fb1744831db5657331627aEcd` |
| `EnclaveRegistry` | `0x2aB29978069dd277B11da118D8fEb160c281A8Ac` |
| `PerformanceLedger` | `0x7872610DF425FC201815AeeEf9Cb58B554e63259` |
| `StrategyRegistry` | `0xA83967EB088806724B2a8baa484BafE02e68Adfd` |
| `FdcVerification` (Flare's) | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |
| `FtsoV2` (Flare's) | `0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d` |

All 4 core contracts verified on Blockscout (Coston2 explorer).

## Enclave signer history

The signer registered in `EnclaveRegistry` for `AlphaVault` has been rotated twice — both times via a
genuine FDC `Web2Json` attestation round-trip (real Coston2 voting round, real on-chain
`verifyWeb2Json` check), not a shortcut.

| Event | Signer | Tx hash |
|---|---|---|
| Initial registration (Week 1, Day 5) | `0x7Df8429dA7215C2e7c3e8725AD5a2C307570bb91` | `0xaff1e898e5df1428822c547c2115cdd10149faf5373679a197f7a55a0d1377bd` |
| Rotation #1 (Week 1, Day 5 — original signer's key was ephemeral and unrecoverable) | `0xa8E2E5B554Aa24160BFA89320D354bdA2CE1f85E` | `0x2cac18f237fe46edcfe4aaf4ab81c172f2b681cc8e524b1d11c8338f881cb090` |
| Rotation #2 (Week 2, Day 1 — same reason: previous signer's key was never persisted, confirmed lost) | `0x7B86a2AD6Fefa227FA385D9764caC5938f22348e` | `0xaf96925183ac5027f2cfb250e125b91ccbd7932bbf5407120a7c58cc47a5254b` |

**Current registered signer (verified live via `signerOf()` on 2026-07-16): `0x7B86a2AD6Fefa227FA385D9764caC5938f22348e`.**

Lesson carried forward from the first rotation: enclave signer private keys generated via
`cast wallet new` must be captured and saved the moment they're created — they are not
recoverable from any on-chain state or log afterward. This has now happened twice; process going
forward is documented in `backend/backend/docs/Commands.md`.

## Automated trading loop

Backend track built and deployed a scheduled trading loop (`backend/backend/relayer/src/tradingLoop.ts`)
that runs continuously (via `pm2`, auto-restarts on crash) and:
1. Reads live FTSOv2 prices for the vault's underlying and trade assets every 5 minutes.
2. If price moves >0.5% since the last check, signs a `TradeInstruction` (EIP-712) with the
   registered enclave signer and calls `AlphaVault.submitInstruction()`.
3. Retries transient RPC read failures (up to 3 attempts with backoff) so a brief Coston2 RPC
   hiccup doesn't cost a full 5-minute cycle.

**Status as of 2026-07-16: running continuously since 2026-07-14, no trade has fired yet** — the
0.5% momentum threshold hasn't been crossed by real FTSOv2 price movement during this window. This
is the strategy behaving conservatively, not a malfunction; confirmed by reviewing
`relayer/tradingLoop.log`, which shows regular ticks with correctly-computed (sub-threshold)
price deltas throughout.

## Pending trade (manual, Week 1)

A `TradeInstruction` was signed for a manual test trade (asset `0x7A2eD27554A1F5003AAaedf3A3B5f35Ca44F6EbE`,
nonce `1`) but has not been submitted on-chain as of this writing — confirmed directly via
`cast call`, not secondhand:
- `PerformanceLedger.epochCount()` → `0`
- `AlphaVault.usedNonces(1)` → `false`

## Known issue flagged, not yet resolved

The `PRIVATE_KEY` in `contracts/.env` (labeled "Deployed private key") was discovered on 2026-07-14
to actually be the contract owner's key (`0x1B25f228bEA51f0f7239E3C753904a4489014757`), not a
disposable deployer key. It has been used in several scripts/terminals this week. Flagged to the
team; recommended action is to move any real value off that address and/or rotate ownership
(`Ownable2Step.transferOwnership`) rather than continue treating it as a plaintext-safe key.

## TEE attestation: current honest status

The entire attestation pipeline (enclave → relayer → FDC → `EnclaveRegistry`) is real and
independently verifiable on-chain — the FDC voting rounds, Merkle proofs, and
`EnclaveRegistry.isValidSigner()` checks are all genuine, not mocked.

**What is mocked**: the attestation *claim itself* is not a real Google Confidential Space
attestation JWT. It's a locally-generated JSON document with the same field shape
(`iss: "local-mock-attestation-service"`, `mock: true`), produced by an ordinary Node process
rather than genuine confidential-computing hardware. This was a deliberate Week 1 scope cut after
hitting a GCP billing wall (India-region ₹1,000 prepayment requirement, failed card verification
attempts) — documented at the time, not discovered after the fact.

**Team decision (Week 2, Day 4)**: confirmed with Kundan not to re-attempt real Google Confidential
Space this sprint — no further GCP spend, time better spent hardening the trading loop instead
(Day 4's retry-logic work above). This is being formally recorded here as the documented-mock path,
per the Week 2 sprint plan's "Decision Needed This Week" item, so the submission write-up is
unambiguous about what's real vs. mocked rather than leaving it implicit.
