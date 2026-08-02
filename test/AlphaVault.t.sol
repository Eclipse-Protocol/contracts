// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AlphaVault} from "../src/core/AlphaVault.sol";
import {IAlphaVault} from "../src/interfaces/IAlphaVault.sol";
import {EnclaveRegistry} from "../src/core/EnclaveRegistry.sol";
import {PerformanceLedger} from "../src/core/PerformanceLedger.sol";
import {IFdcVerification, IWeb2Json} from "../src/interfaces/IFdcVerification.sol";
import {IEnclaveRegistry} from "../src/interfaces/IEnclaveRegistry.sol";
import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";

import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockDexRouter} from "../src/mocks/MockDexRouter.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";
import {MockEnclaveSigner} from "../src/mocks/MockEnclaveSigner.sol";

contract AlphaVaultTest is Test {
    bytes21 internal constant FEED_BASE = bytes21(uint168(1));
    bytes21 internal constant FEED_SAT = bytes21(uint168(2));

    uint256 internal constant MAX_POSITION_SIZE_BPS = 5_000; // 50% of TVL
    // Must stay above ~1667 bps: the genesis high-water mark (1.2x) sits ~16.67% above the genesis
    // PPS (1.0x), so any threshold below that gap trips the breaker on the very first trade before
    // any real drawdown occurs.
    uint256 internal constant MAX_DRAWDOWN_BPS = 2_000; // 20%

    MockERC20 internal underlying;
    MockERC20 internal satellite;
    MockDexRouter internal router;
    MockFtsoV2 internal ftso;
    MockFdcVerification internal fdc;
    PerformanceLedger internal ledger;
    EnclaveRegistry internal registry;
    MockEnclaveSigner internal enclaveSigner;
    AlphaVault internal vault;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal strategist = makeAddr("strategist");
    address internal investor1 = makeAddr("investor1");

    function setUp() public {
        underlying = new MockERC20("Mock USD", "mUSD", 18);
        satellite = new MockERC20("Mock FXRP", "mFXRP", 18);

        router = new MockDexRouter();
        router.setRate(address(underlying), address(satellite), 0.5e18); // 1 mUSD -> 0.5 mFXRP
        router.setRate(address(satellite), address(underlying), 2e18); // 1 mFXRP -> 2 mUSD

        ftso = new MockFtsoV2();
        ftso.setPrice(FEED_BASE, 1e18, uint64(block.timestamp)); // $1
        ftso.setPrice(FEED_SAT, 2e18, uint64(block.timestamp)); // $2 -> consistent with DEX rate

        fdc = new MockFdcVerification();
        ledger = new PerformanceLedger(owner);
        registry = new EnclaveRegistry(owner, IFdcVerification(address(fdc)));
        enclaveSigner = new MockEnclaveSigner(uint256(keccak256("enclave-test-key")));

        vault = new AlphaVault(
            IERC20(address(underlying)),
            "Eclipse Alpha Vault Shares",
            "eaVLT",
            owner,
            treasury,
            strategist,
            IEnclaveRegistry(address(registry)),
            IDexRouter(address(router)),
            IFtsoV2(address(ftso)),
            ledger,
            MAX_POSITION_SIZE_BPS,
            MAX_DRAWDOWN_BPS
        );

        vm.prank(owner);
        ledger.setVault(address(vault));

        vm.startPrank(owner);
        vault.setFeedId(address(underlying), FEED_BASE);
        vault.setFeedId(address(satellite), FEED_SAT);
        vm.stopPrank();

        IWeb2Json.Proof memory proof = fdc.buildProof(address(vault), enclaveSigner.enclaveAddress());
        registry.registerEnclave(address(vault), enclaveSigner.enclaveAddress(), proof);

        underlying.mint(investor1, 10_000e18);
        vm.prank(investor1);
        underlying.approve(address(vault), type(uint256).max);
    }

    function _buildInstruction(
        address asset,
        IAlphaVault.TradeDirection direction,
        uint256 size,
        uint256 minAmountOut,
        uint256 nonce
    ) internal view returns (IAlphaVault.TradeInstruction memory) {
        return IAlphaVault.TradeInstruction({
            asset: asset,
            direction: direction,
            size: size,
            minAmountOut: minAmountOut,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _signedBuy(uint256 size, uint256 minOut, uint256 nonce)
        internal
        view
        returns (IAlphaVault.TradeInstruction memory instruction, bytes memory signature)
    {
        instruction =
            _buildInstruction(address(satellite), IAlphaVault.TradeDirection.Buy, size, minOut, nonce);
        bytes32 digest = vault.hashTradeInstruction(instruction);
        signature = enclaveSigner.sign(digest);
    }

    // ---------------------------------------------------------------------
    // Deposit / withdraw
    // ---------------------------------------------------------------------

    function test_deposit_mintsSharesOneToOneAtGenesis() public {
        vm.prank(investor1);
        uint256 shares = vault.deposit(1_000e18, investor1);

        assertEq(shares, 1_000e18);
        assertEq(vault.totalAssets(), 1_000e18);
        assertEq(vault.totalSupply(), 1_000e18);
        assertEq(vault.highWaterMark(), 1.2e18);
    }

    function test_withdraw_returnsUnderlyingCorrectly() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        vm.prank(investor1);
        uint256 assetsOut = vault.redeem(400e18, investor1, investor1);

        assertEq(assetsOut, 400e18);
        assertEq(underlying.balanceOf(investor1), 10_000e18 - 1_000e18 + 400e18);
        assertEq(vault.totalSupply(), 600e18);
    }

    // ---------------------------------------------------------------------
    // submitInstruction — signature validation
    // ---------------------------------------------------------------------

    function test_submitInstruction_validSignature_executesTradeAndCommitsEpoch() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(100e18, 40e18, 1);
        vault.submitInstruction(instruction, signature);

        assertEq(underlying.balanceOf(address(vault)), 900e18);
        assertEq(satellite.balanceOf(address(vault)), 50e18);
        assertEq(vault.currentPosition(), address(satellite));
        assertEq(vault.cachedPositionValue(), 100e18); // 50 mFXRP * $2 / $1
        assertEq(vault.totalAssets(), 1_000e18); // value-preserving swap, no P&L yet
        assertTrue(vault.usedNonces(1));

        assertEq(ledger.epochCount(), 1);
        PerformanceLedger.Epoch memory epoch = ledger.getEpoch(0);
        assertEq(epoch.nav, 1_000e18);
        assertTrue(ledger.verifyChain());

        // No fee should have been minted: PPS is still 1.0, below the 1.2 genesis hurdle.
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.balanceOf(strategist), 0);
    }

    function test_submitInstruction_invalidSigner_reverts() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        uint256 rogueKey = uint256(keccak256("rogue-key"));
        address rogueSigner = vm.addr(rogueKey);

        IAlphaVault.TradeInstruction memory instruction =
            _buildInstruction(address(satellite), IAlphaVault.TradeDirection.Buy, 100e18, 40e18, 1);
        bytes32 digest = vault.hashTradeInstruction(instruction);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(AlphaVault.InvalidSigner.selector, rogueSigner));
        vault.submitInstruction(instruction, signature);
    }

    function test_submitInstruction_replayedNonce_reverts() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(100e18, 40e18, 1);
        vault.submitInstruction(instruction, signature);

        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NonceAlreadyUsed.selector, uint256(1)));
        vault.submitInstruction(instruction, signature);
    }

    function test_submitInstruction_expiredDeadline_reverts() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        IAlphaVault.TradeInstruction memory instruction = IAlphaVault.TradeInstruction({
            asset: address(satellite),
            direction: IAlphaVault.TradeDirection.Buy,
            size: 100e18,
            minAmountOut: 40e18,
            nonce: 1,
            deadline: block.timestamp
        });
        bytes32 digest = vault.hashTradeInstruction(instruction);
        bytes memory signature = enclaveSigner.sign(digest);

        vm.warp(block.timestamp + 1);

        vm.expectRevert(
            abi.encodeWithSelector(AlphaVault.InstructionExpired.selector, instruction.deadline, block.timestamp)
        );
        vault.submitInstruction(instruction, signature);
    }

    // ---------------------------------------------------------------------
    // Risk limits
    // ---------------------------------------------------------------------

    function test_submitInstruction_exceedsMaxPositionSize_reverts() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        // 50% of 1000e18 TVL = 500e18 max; request 600e18.
        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(600e18, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(AlphaVault.PositionTooLarge.selector, 600e18, 500e18));
        vault.submitInstruction(instruction, signature);
    }

    function test_drawdownCircuitBreaker_pausesNewTrades() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(100e18, 40e18, 1);
        vault.submitInstruction(instruction, signature);

        // Crash the satellite asset's price 90% (2e18 -> 0.2e18): NAV drops from 1000 to 910,
        // an ~24% drawdown from the 1.2e18 genesis high-water mark — past the 20% breaker threshold.
        ftso.setPrice(FEED_SAT, 0.2e18, uint64(block.timestamp));
        vault.refreshPositionValue();
        vault.checkDrawdown();

        assertTrue(vault.paused());

        (IAlphaVault.TradeInstruction memory instruction2, bytes memory signature2) = _signedBuy(10e18, 1, 2);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.submitInstruction(instruction2, signature2);

        vm.prank(owner);
        vault.resetCircuitBreaker();
        assertFalse(vault.paused());
    }

    // ---------------------------------------------------------------------
    // Harvest — atomic-on-trade and standalone idempotency
    // ---------------------------------------------------------------------

    function test_submitInstruction_atomicHarvestOnNewHigh() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(100e18, 40e18, 1);
        vault.submitInstruction(instruction, signature);

        // Pump the satellite price 15x (2e18 -> 30e18): NAV rises well above the 1.2 hurdle.
        ftso.setPrice(FEED_SAT, 30e18, uint64(block.timestamp));

        // A second (small) trade is enough to trigger the atomic _harvest() path at the tail end of
        // submitInstruction — fees must be minted in the SAME transaction as the trade, with no
        // separate explicit harvest() call.
        (IAlphaVault.TradeInstruction memory instruction2, bytes memory signature2) = _signedBuy(1e18, 1, 2);
        vault.submitInstruction(instruction2, signature2);

        assertGt(vault.balanceOf(treasury), 0);
        assertGt(vault.balanceOf(strategist), 0);
        assertGt(vault.highWaterMark(), 1.2e18);

        // Idempotency: with no further price movement, a subsequent harvest is a strict no-op.
        uint256 hwmAfter = vault.highWaterMark();
        uint256 treasuryAfter = vault.balanceOf(treasury);
        uint256 strategistAfter = vault.balanceOf(strategist);
        vault.harvest();
        assertEq(vault.highWaterMark(), hwmAfter);
        assertEq(vault.balanceOf(treasury), treasuryAfter);
        assertEq(vault.balanceOf(strategist), strategistAfter);
    }

    function test_harvest_standaloneIsIdempotent() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(100e18, 40e18, 1);
        vault.submitInstruction(instruction, signature);

        ftso.setPrice(FEED_SAT, 30e18, uint64(block.timestamp));

        vault.harvest();
        uint256 treasuryAfterFirst = vault.balanceOf(treasury);
        uint256 strategistAfterFirst = vault.balanceOf(strategist);
        assertGt(treasuryAfterFirst, 0);
        assertGt(strategistAfterFirst, 0);

        // Second call with no new price movement must be a strict no-op.
        vault.harvest();
        assertEq(vault.balanceOf(treasury), treasuryAfterFirst);
        assertEq(vault.balanceOf(strategist), strategistAfterFirst);
    }

    function test_harvest_noFeeWhenBelowHurdle() public {
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);

        (IAlphaVault.TradeInstruction memory instruction, bytes memory signature) = _signedBuy(100e18, 40e18, 1);
        vault.submitInstruction(instruction, signature);

        // Satellite price doubles ($2 -> $4): position value 100e18 -> 200e18, total NAV
        // 900 + 200 = 1100e18 against 1000e18 supply => PPS = 1.1e18, still below the 1.2 hurdle.
        ftso.setPrice(FEED_SAT, 4e18, uint64(block.timestamp));
        vault.harvest();

        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.balanceOf(strategist), 0);
        assertEq(vault.highWaterMark(), 1.2e18);
    }

    // ---------------------------------------------------------------------
    // Regression: mismatched underlying/satellite decimals (Coston2 production shape —
    // 6-decimal Mock USDC underlying against an 18-decimal satellite — previously
    // overstated cachedPositionValue by 10^12, permanently corrupting highWaterMark.
    // ---------------------------------------------------------------------

    struct MismatchedDecimalsFixture {
        MockERC20 underlying6;
        MockERC20 satellite18;
        MockDexRouter router;
        MockFtsoV2 ftso;
        PerformanceLedger ledger;
        AlphaVault vault;
    }

    /// @dev Deploys and wires a fresh vault on a 6-decimal underlying / 18-decimal satellite pair,
    /// mirroring the real Coston2 deployment shape, but does NOT deposit — lets callers inspect
    /// genesis state (e.g. {highWaterMark}) before any supply/assets exist.
    function _deployMismatchedDecimalsVaultUnfunded() internal returns (MismatchedDecimalsFixture memory f) {
        f.underlying6 = new MockERC20("Mock USDC", "mUSDC", 6);
        f.satellite18 = new MockERC20("Mock FLR", "mFLR", 18);

        f.router = new MockDexRouter();
        // 100 mUSDC (1e8 raw, 6dp) -> 50 mFLR (5e19 raw, 18dp): consistent with $1 / $2 FTSO prices below.
        f.router.setRate(address(f.underlying6), address(f.satellite18), 5e29);

        f.ftso = new MockFtsoV2();
        f.ftso.setPrice(FEED_BASE, 1e18, uint64(block.timestamp)); // $1
        f.ftso.setPrice(FEED_SAT, 2e18, uint64(block.timestamp)); // $2

        f.ledger = new PerformanceLedger(owner);
        EnclaveRegistry registry2 = new EnclaveRegistry(owner, IFdcVerification(address(fdc)));

        f.vault = new AlphaVault(
            IERC20(address(f.underlying6)),
            "Eclipse Alpha Vault Shares",
            "eaVLT",
            owner,
            treasury,
            strategist,
            IEnclaveRegistry(address(registry2)),
            IDexRouter(address(f.router)),
            IFtsoV2(address(f.ftso)),
            f.ledger,
            MAX_POSITION_SIZE_BPS,
            MAX_DRAWDOWN_BPS
        );

        vm.prank(owner);
        f.ledger.setVault(address(f.vault));

        vm.startPrank(owner);
        f.vault.setFeedId(address(f.underlying6), FEED_BASE);
        f.vault.setFeedId(address(f.satellite18), FEED_SAT);
        vm.stopPrank();

        IWeb2Json.Proof memory proof = fdc.buildProof(address(f.vault), enclaveSigner.enclaveAddress());
        registry2.registerEnclave(address(f.vault), enclaveSigner.enclaveAddress(), proof);
    }

    /// @dev Same as {_deployMismatchedDecimalsVaultUnfunded}, funded with a 1,000-unit investor1 deposit.
    function _deployMismatchedDecimalsVault() internal returns (MismatchedDecimalsFixture memory f) {
        f = _deployMismatchedDecimalsVaultUnfunded();

        f.underlying6.mint(investor1, 1_000e6);
        vm.prank(investor1);
        f.underlying6.approve(address(f.vault), type(uint256).max);
        vm.prank(investor1);
        f.vault.deposit(1_000e6, investor1);
    }

    function test_refreshPositionValue_handlesMismatchedDecimals() public {
        MismatchedDecimalsFixture memory f = _deployMismatchedDecimalsVault();

        IAlphaVault.TradeInstruction memory instruction = IAlphaVault.TradeInstruction({
            asset: address(f.satellite18),
            direction: IAlphaVault.TradeDirection.Buy,
            size: 100e6,
            minAmountOut: 40e18,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = f.vault.hashTradeInstruction(instruction);
        bytes memory signature = enclaveSigner.sign(digest);
        f.vault.submitInstruction(instruction, signature);

        // 50 mFLR at $2 == $100 == 100e6 in the underlying's 6-decimal terms, NOT 100e18.
        assertEq(f.vault.cachedPositionValue(), 100e6);
        // Value-preserving swap: NAV should still read ~1000 (900 underlying + 100 position value),
        // not the ~10^12-inflated figure the pre-fix formula would have produced.
        assertEq(f.vault.totalAssets(), 1_000e6);
        assertEq(f.vault.highWaterMark(), 1.2e18); // untouched: PPS still below the genesis hurdle
    }

    // ---------------------------------------------------------------------
    // Sprint 3 Day 1: synthetic profitable harvest — proves the 3%/7% treasury/strategist fee
    // split fires with the EXACT expected share amounts (not just "some fee > 0"), on the same
    // mismatched-decimals shape as the real deployment, independent of whether any given week's
    // real automated trades happen to be profitable.
    // ---------------------------------------------------------------------

    function test_harvest_mintsExactTreasuryStrategistSplitOnNewHigh() public {
        MismatchedDecimalsFixture memory f = _deployMismatchedDecimalsVault();

        IAlphaVault.TradeInstruction memory instruction = IAlphaVault.TradeInstruction({
            asset: address(f.satellite18),
            direction: IAlphaVault.TradeDirection.Buy,
            size: 100e6,
            minAmountOut: 40e18,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = f.vault.hashTradeInstruction(instruction);
        f.vault.submitInstruction(instruction, enclaveSigner.sign(digest));

        // Pump the satellite price 15x ($2 -> $30), same multiple as the same-decimal harvest test,
        // so NAV rises well above the 1.2x genesis hurdle: 900e6 + 50e18*$30/$1(in 6dp) = 900e6 + 1_500e6.
        f.ftso.setPrice(FEED_SAT, 30e18, uint64(block.timestamp));
        f.vault.refreshPositionValue();

        uint256 assetsBefore = f.vault.totalAssets();
        uint256 supplyBefore = f.vault.totalSupply();
        uint256 ppsBefore = (assetsBefore * 1e18) / supplyBefore;
        uint256 hwmBefore = f.vault.highWaterMark();
        assertGt(ppsBefore, hwmBefore, "sanity: pump must clear the hurdle");

        // Mirror FeeMath.computeFeeShares exactly to compute the expected split independently.
        uint256 gainPerShare = ppsBefore - hwmBefore;
        uint256 totalGainValue = (gainPerShare * supplyBefore) / 1e18;
        uint256 feeValue = (totalGainValue * 1_000) / 10_000; // 10% performance fee
        uint256 expectedCombined = (feeValue * supplyBefore) / (assetsBefore - feeValue);
        uint256 expectedTreasury = (expectedCombined * 300) / 1_000; // 3%
        uint256 expectedStrategist = expectedCombined - expectedTreasury; // 7%

        f.vault.harvest();

        assertEq(f.vault.balanceOf(treasury), expectedTreasury);
        assertEq(f.vault.balanceOf(strategist), expectedStrategist);
        assertGt(expectedTreasury, 0);
        assertGt(expectedStrategist, 0);
        assertEq(f.vault.highWaterMark(), ppsBefore);
    }

    // ---------------------------------------------------------------------
    // Regression: suspected-but-unconfirmed second decimals bug in HWM seeding/comparison
    // (flagged 2026-08-02) — the theory was that the constructor might derive genesis
    // {highWaterMark} from live state using the underlying's raw decimals rather than a fixed
    // WAD constant, producing something on the order of 1e29 instead of 1.2e18 once a 6-decimal
    // underlying is involved. Closes the exact coverage gap called out: assert the value
    // immediately after construction, before any deposit exists.
    // ---------------------------------------------------------------------

    function test_highWaterMark_seededCorrectlyBeforeAnyDeposit_mismatchedDecimals() public {
        MismatchedDecimalsFixture memory f = _deployMismatchedDecimalsVaultUnfunded();

        assertEq(f.vault.totalAssets(), 0);
        assertEq(f.vault.totalSupply(), 0);
        assertEq(f.vault.highWaterMark(), 1.2e18, "genesis HWM must be the fixed WAD constant, not derived from 0/0 state");
    }
}
