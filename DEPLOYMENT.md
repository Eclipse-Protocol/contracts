# Eclipse Protocol — Deployment & Live Status

Coston2 testnet (chain id `114`). Last updated 2026-07-27 (Week 3, Day 1).

## Deployed contracts (current, live)

| Contract | Address |
|---|---|
| `AlphaVault` | `0x0c06133c6F6F843707A239A24903b66b3004E19a` |
| `PerformanceLedger` | `0x67f2CaACEf26472226FDe1341c90004A4BE5059a` |
| `StrategyRegistry` | `0xc1Ee140CAaEb8256bb80aE0E1aeE4bD8BfDC73a8` |
| `MockDexRouter` | `0x9B1b742477ECf3810e2184De0959e9C75268aD21` |
| Bond token (`eBOND`) | `0x88111bF10C59d828F20760F2604E833eB9c452e8` |
| `EnclaveRegistry` (unchanged since Week 1) | `0x2aB29978069dd277B11da118D8fEb160c281A8Ac` |
| `FdcVerification` (Flare's) | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |
| `FtsoV2` (Flare's) | `0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d` |
| Current owner (all owner-gated contracts) | `0xb4DAe7f0632168F8Ad0457506E3F4b1813d27f60` |
| Current registered enclave signer | `0x7B86a2AD6Fefa227FA385D9764caC5938f22348e` |

**Orphaned / do-not-use addresses** (kept here for history, not live): original `AlphaVault`
`0x1b0cf88974ffBC1Fb1744831db5657331627aEcd` + `PerformanceLedger` `0x7872610DF425FC201815AeeEf9Cb58B554e63259`
(corrupted `highWaterMark`, permanently paused — see "NAV decimals bug" below); a first redeploy
attempt `0xE14e67EA1b6a4e909198520005134e0dDeF237dc` / `0xf7b5CF940e7f5827B1dB3d420207aB6F9eC1Be8F`
(never registered/funded, wired to Coston2's real BlazeSwap router instead of `MockDexRouter`);
original `StrategyRegistry` `0xA83967EB088806724B2a8baa484BafE02e68Adfd` (immutable `bondToken` pointed
at an address with zero deployed code — `registerStrategy()` could never have succeeded); real
BlazeSwap router `0xe3A1b355ca63abCBC9589334B5e609583C7BAa06` (Coston2 infrastructure, not ours —
was briefly mis-wired as `AlphaVault.dexRouter()`, never a "deployment" of ours).

All contracts verified on Blockscout (Coston2 explorer).

## Week 3, Day 1 — NAV decimals bug, redeploy, and security hardening

Stating this plainly rather than obscuring it, per the team's own submission-write-up standard.

### 1. NAV decimals bug (why a redeploy was needed at all)

`AlphaVault._refreshPositionValue()` computed `cachedPositionValue = (posBalance * posPrice) / basePrice`
without adjusting for the position token's decimals vs. the underlying's (Coston2 setup: underlying
"Mock USDC" = 6 decimals, satellite trade asset = 18 decimals). This overstated NAV by ~10^12x after
the first real trade, permanently corrupting `highWaterMark` (contracts are immutable, no owner
setter exists to lower it) — which then re-tripped the circuit breaker after every subsequent trade.

**Fix**: `_refreshPositionValue()` now scales the calculation via `IERC20Metadata(token).decimals()`
for both sides. Regression test `test_refreshPositionValue_handlesMismatchedDecimals` added to
`test/AlphaVault.t.sol` using a 6/18-decimal pair mirroring production — the original suite only
ever used same-decimal tokens, which is exactly how this shipped unnoticed. Full suite: **35/35
passing**.

**Redeploy required two attempts**: the first (`0xE14e67EA1b6a4e909198520005134e0dDeF237dc`) inherited
a stale `.env` value and got wired to the real BlazeSwap router instead of `MockDexRouter` — caught
before it was ever funded or registered, then orphaned. The second attempt (current, `0x0c06133c...`)
was verified correct on every wiring dimension before funding: `dexRouter()`, `performanceLedger()`,
`enclaveRegistry()`, `feedIdOf()` for both tokens, `isValidSigner()`.

### 2. Circuit-breaker misconfiguration (found independently, not in the original bug report)

The genesis high-water mark (`1.2e18`) sits ~16.67% above genesis price-per-share (`1.0e18`) by
design (the protocol's built-in "prove yourself first" hurdle) — but `maxDrawdownBps` was set to
`1500` (15%), *below* that built-in gap. This meant the circuit breaker would trip after essentially
any first trade, profitable or not, purely from the genesis-mark headstart — nothing to do with real
performance. Confirmed live: after one real trade, PPS ≈ `0.95e18` against `highWaterMark = 1.2e18`,
an apparent ~20.8% drawdown, past the 15% threshold — vault paused itself immediately.

**Fix**: `setMaxDrawdownBps(2500)` (25%) via owner tx — plain runtime setter, not baked into
immutable bytecode, so **no redeploy needed**. Tx: `0x509238079a38e9659a6e9bb4784206f00df4343941419a032481f4352d353939`.

### 3. `StrategyRegistry` was dead on arrival

The original `StrategyRegistry`'s immutable `bondToken()` (`0xC8C0F595...4E4a`) had **zero deployed
code** on Coston2 — `registerStrategy()` could never have succeeded, for any vault, ever. Deployed a
real bond token (`eBOND`, `0x88111bF1...c452e8`) + a fresh `StrategyRegistry` pointing at it (cheap
fix: nothing had ever been registered on the old one, confirmed via `isRegistered()` before
redeploying — no data loss). Registered the current vault's strategy:
tx `0x49fcee6c50d3e3d46c4d2004e30d7b1a0272138e10db438f28afb8e6489e6b29`,
`getStrategyByVault()` now returns real data instead of reverting `VaultNotRegistered`.

Also added `test_harvest_mintsExactTreasuryStrategistSplitOnNewHigh` — asserts the *exact* 3%/7%
treasury/strategist share split fires correctly on the mismatched-decimals shape, independent of
whether any given week's real trades happen to be profitable.

### 4. Owner-key rotation (security gap flagged across three sprint reports, now closed)

The original owner key (`0x1B25f228bEA51f0f7239E3C753904a4489014757`) had its private key pasted
into terminals/screenshots repeatedly across the project. Rotated via the full `Ownable2Step`
handoff (`transferOwnership` → `acceptOwnership`) on all four owner-gated contracts:

| Contract | `transferOwnership` tx | `acceptOwnership` tx |
|---|---|---|
| `AlphaVault` | `0x0371eb30af7e5333d0e7e9fd24592a02a5659bec3fb5cf5401b6dad94be3c0e5` | `0x9d7ac5189d42cd7027a07f0389829c14f9c0ba34f48eb89a0823d4e2dbe4b775` |
| `EnclaveRegistry` | `0x086eadda737c48159b236319435f1596821790f19cd5fc6d362d28e9b7d92f2c` | `0x2b28ddd6ebbd31889de2d4ba5a6c1a83473b4edab5d694f8b0dd1bfaa4b54567` |
| `PerformanceLedger` | `0x47f9144f206c29ff4575d9eec28b8e5de0b0028530e2947494800d7398e8862b` | `0x42df973f3b6ee03c91110ca165aa025416654624002c3f3bd33757edcff04fd2` |
| `StrategyRegistry` | `0x7143928d78c54f4ac13d10a120cff71f5a52626e319c87789932794f4dabdaa9` | `0x7b4a293b5bf1d0e79dd8e19a7b20d48e03298732c8c996fb8402be7aae2b2dbc` |

New owner: `0xb4DAe7f0632168F8Ad0457506E3F4b1813d27f60`. **Independently verified the old key is
actually powerless** (not just trusted the `owner()` read) by attempting an owner-gated call from it
post-rotation — reverted with `OwnableUnauthorizedAccount`, as expected.

### 5. Trading loop silent death (backend/ops, not a contracts bug)

The loop ran correctly after the redeploy (one real trade landed,
`0xa30250d27e87eb597c057a486817ece4ad66198c16fd5e81185ecb93cdaa8643`), hit the pre-fix circuit-breaker
bug on the next tick as expected, then the process itself was killed with no error trace around
2026-07-20T18:32 UTC — never `pm2 save`'d, so `pm2` had no record to restore it. Root-caused via
`relayer/tradingLoop.log` directly rather than guessing. Restarted 2026-07-24 with `pm2 save`; team
also queued `pm2-windows-startup` so this doesn't repeat on a reboot.

## Enclave signer history

The signer registered in `EnclaveRegistry` has been rotated twice and re-registered once more after
the Week 3 vault redeploy — every event via a genuine FDC `Web2Json` attestation round-trip (real
Coston2 voting round, real on-chain `verifyWeb2Json` check), not a shortcut.

| Event | Signer | Tx hash |
|---|---|---|
| Initial registration (Week 1, Day 5) | `0x7Df8429dA7215C2e7c3e8725AD5a2C307570bb91` | `0xaff1e898e5df1428822c547c2115cdd10149faf5373679a197f7a55a0d1377bd` |
| Rotation #1 (Week 1, Day 5 — original signer's key was ephemeral and unrecoverable) | `0xa8E2E5B554Aa24160BFA89320D354bdA2CE1f85E` | `0x2cac18f237fe46edcfe4aaf4ab81c172f2b681cc8e524b1d11c8338f881cb090` |
| Rotation #2 (Week 2, Day 1 — same reason: previous signer's key was never persisted, confirmed lost) | `0x7B86a2AD6Fefa227FA385D9764caC5938f22348e` | `0xaf96925183ac5027f2cfb250e125b91ccbd7932bbf5407120a7c58cc47a5254b` |
| Re-registration for redeployed vault (Week 3, Day 1 — `EnclaveRegistry` is keyed by vault address, so the decimals-bug redeploy needed a fresh real FDC round-trip even though it's the same signer key) | `0x7B86a2AD6Fefa227FA385D9764caC5938f22348e` | `0x8d9843b773f418239eab589b021519bdf0018091d959a8d4d486fba1feae3b03` |

**Current registered signer (verified live via `signerOf(0x0c06133c...)` on 2026-07-27): `0x7B86a2AD6Fefa227FA385D9764caC5938f22348e`.**

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

**Status as of 2026-07-31**: pointed at the current live vault, unpaused, `pm2 save` run so it
survives a reboot going forward. One real trade has landed on the current vault so far
(`0xa30250d27e87eb597c057a486817ece4ad66198c16fd5e81185ecb93cdaa8643`, `epochCount` `0→1`) — see
"Week 3, Day 1" above for the circuit-breaker fix that unblocks further trades from tripping the
breaker on a false gap.

**Correction to an earlier entry in this file**: the previous note claimed the loop was restarted
2026-07-24 — checked directly (not just trusted) and this was inaccurate. `pm2 status` showed a
stale "online" entry with `PID: N/A` and `0mb` memory (a zombie process record, not a real running
process), and `tradingLoop.log`'s actual last entry was still 2026-07-20 — a full outage of roughly
11 days that the prior "restarted" note missed. Restarted for real 2026-07-31, verified via a fresh
timestamped log line and a live tick, not just `pm2 status`'s claim. `pm2-windows-startup` (present
in the earlier note as "queued") had never actually been registered — run for real this session
(`pm2-startup install` + `pm2 save`), so the loop now survives both a crash and a full machine
reboot, not just the former. Also added an optional `GET /status` endpoint (`STATUS_PORT` in
`.env`, default `3002`) reporting `lastTickAt`/`lastDecision`, for the frontend's "Enclave: Live"
indicator — confirmed live via a real request, not just code review.

## Pending trade (manual, Week 1) — superseded

The Week 1 manually-signed test instruction was never submitted before the Week 3 redeploy made
that vault/ledger pair orphaned (see "Deployed contracts" above). Superseded by the real trade
history now accumulating on the current vault — see "Automated trading loop" above.

## Owner-key exposure — resolved 2026-07-27

The `PRIVATE_KEY` in `contracts/.env` (labeled "Deployed private key") was discovered on 2026-07-14
to actually be the contract owner's key (`0x1B25f228bEA51f0f7239E3C753904a4489014757`), not a
disposable deployer key, and had been pasted into terminals/screenshots repeatedly. Flagged across
three consecutive sprint reports; resolved via full ownership rotation — see "Week 3, Day 1" section
above for the complete transfer/accept tx table and the independent verification that the old key
is now genuinely powerless. `PRIVATE_KEY` in `.env` remains the plain deployer/broadcaster for
non-owner-gated actions only (deploys, test-token minting) — never the owner going forward.

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
