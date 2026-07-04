// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AlphaVault} from "../../src/core/AlphaVault.sol";
import {IAlphaVault} from "../../src/interfaces/IAlphaVault.sol";
import {EnclaveRegistry} from "../../src/core/EnclaveRegistry.sol";
import {PerformanceLedger} from "../../src/core/PerformanceLedger.sol";
import {StrategyRegistry} from "../../src/core/StrategyRegistry.sol";
import {IFdcVerification, IWeb2Json} from "../../src/interfaces/IFdcVerification.sol";
import {IEnclaveRegistry} from "../../src/interfaces/IEnclaveRegistry.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {IFtsoV2} from "../../src/interfaces/IFtsoV2.sol";

import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockDexRouter} from "../../src/mocks/MockDexRouter.sol";
import {MockFtsoV2} from "../../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../../src/mocks/MockFdcVerification.sol";
import {MockEnclaveSigner} from "../../src/mocks/MockEnclaveSigner.sol";

/// @notice End-to-end run through the full protocol lifecycle: enclave attestation, strategist
/// bonding, multi-investor deposits at different NAVs, a sequence of profitable/unprofitable trades,
/// sequential fee harvests, and final withdrawals — asserting every party ends up with the correct
/// balance and that no depositor is ever retroactively charged a fee on profit that predates them.
contract FullFlowTest is Test {
    bytes21 internal constant FEED_BASE = bytes21(uint168(1));
    bytes21 internal constant FEED_SAT = bytes21(uint168(2));

    MockERC20 internal underlying;
    MockERC20 internal satellite;
    MockERC20 internal bondToken;
    MockDexRouter internal router;
    MockFtsoV2 internal ftso;
    MockFdcVerification internal fdc;
    PerformanceLedger internal ledger;
    EnclaveRegistry internal registry;
    StrategyRegistry internal strategyRegistry;
    MockEnclaveSigner internal enclaveSigner;
    AlphaVault internal vault;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal strategistPayout = makeAddr("strategistPayout");
    address internal strategistCaller = makeAddr("strategistCaller");
    address internal investor1 = makeAddr("investor1");
    address internal investor2 = makeAddr("investor2");

    uint256 internal nonceCounter;

    function setUp() public {
        underlying = new MockERC20("Mock USD", "mUSD", 18);
        satellite = new MockERC20("Mock FXRP", "mFXRP", 18);
        bondToken = new MockERC20("Mock Stake", "mSTK", 18);

        router = new MockDexRouter();
        router.setRate(address(underlying), address(satellite), 0.5e18);
        router.setRate(address(satellite), address(underlying), 2e18);

        ftso = new MockFtsoV2();
        ftso.setPrice(FEED_BASE, 1e18, uint64(block.timestamp));
        ftso.setPrice(FEED_SAT, 2e18, uint64(block.timestamp));

        fdc = new MockFdcVerification();
        ledger = new PerformanceLedger(owner);
        registry = new EnclaveRegistry(owner, IFdcVerification(address(fdc)));
        strategyRegistry = new StrategyRegistry(owner, IERC20(address(bondToken)));
        enclaveSigner = new MockEnclaveSigner(uint256(keccak256("full-flow-enclave-key")));

        vault = new AlphaVault(
            IERC20(address(underlying)),
            "Eclipse Alpha Vault Shares",
            "eaVLT",
            owner,
            treasury,
            strategistPayout,
            IEnclaveRegistry(address(registry)),
            IDexRouter(address(router)),
            IFtsoV2(address(ftso)),
            ledger,
            10_000, // no effective position-size cap for this test
            5_000 // 50% drawdown tolerance, generous for this test's price swings
        );

        vm.prank(owner);
        ledger.setVault(address(vault));

        vm.startPrank(owner);
        vault.setFeedId(address(underlying), FEED_BASE);
        vault.setFeedId(address(satellite), FEED_SAT);
        vm.stopPrank();

        // 1) Enclave attestation.
        IWeb2Json.Proof memory proof = fdc.buildProof(address(vault), enclaveSigner.enclaveAddress());
        registry.registerEnclave(address(vault), enclaveSigner.enclaveAddress(), proof);

        // 2) Strategist bonds stake and registers the strategy.
        bondToken.mint(strategistCaller, 1_000e18);
        vm.startPrank(strategistCaller);
        bondToken.approve(address(strategyRegistry), 1_000e18);
        strategyRegistry.registerStrategy(address(vault), "Eclipse Momentum Strategy", strategistPayout, 1_000e18);
        vm.stopPrank();

        underlying.mint(investor1, 100_000e18);
        underlying.mint(investor2, 100_000e18);
        vm.prank(investor1);
        underlying.approve(address(vault), type(uint256).max);
        vm.prank(investor2);
        underlying.approve(address(vault), type(uint256).max);
    }

    function _submitBuy(uint256 size, uint256 minOut) internal {
        nonceCounter++;
        IAlphaVault.TradeInstruction memory instruction = IAlphaVault.TradeInstruction({
            asset: address(satellite),
            direction: IAlphaVault.TradeDirection.Buy,
            size: size,
            minAmountOut: minOut,
            nonce: nonceCounter,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = vault.hashTradeInstruction(instruction);
        bytes memory signature = enclaveSigner.sign(digest);
        vault.submitInstruction(instruction, signature);
    }

    function test_fullProtocolLifecycle() public {
        assertTrue(strategyRegistry.isRegistered(address(vault)));

        // --- Investor 1 deposits at genesis NAV (PPS = 1.0) ---
        vm.prank(investor1);
        vault.deposit(1_000e18, investor1);
        assertEq(vault.totalAssets(), 1_000e18);

        // --- Trade 1: value-preserving rebalance into the satellite asset ---
        _submitBuy(200e18, 90e18); // 200 mUSD -> 100 mFXRP @ 0.5 rate
        assertEq(vault.currentPosition(), address(satellite));
        assertEq(vault.totalAssets(), 1_000e18); // no P&L yet
        assertEq(vault.balanceOf(treasury), 0, "no fee below hurdle");

        // --- Price pump #1: satellite $2 -> $8 (4x). Standalone permissionless harvest. ---
        ftso.setPrice(FEED_SAT, 8e18, uint64(block.timestamp));
        vault.harvest();

        uint256 hwmAfterFirstHarvest = vault.highWaterMark();
        assertGt(hwmAfterFirstHarvest, 1.2e18, "first harvest must ratchet the high-water mark up");
        uint256 treasuryAfterFirstHarvest = vault.balanceOf(treasury);
        uint256 strategistAfterFirstHarvest = vault.balanceOf(strategistPayout);
        assertGt(treasuryAfterFirstHarvest, 0);
        assertGt(strategistAfterFirstHarvest, 0);
        // 3:7 split ratio (within small rounding tolerance).
        assertApproxEqAbs(strategistAfterFirstHarvest * 3, treasuryAfterFirstHarvest * 7, 5);

        uint256 ppsAfterFirstHarvest = (vault.totalAssets() * 1e18) / vault.totalSupply();

        // --- Investor 2 deposits AFTER the first harvest: must buy in at the new, higher PPS and
        // must never be charged a fee for profit that happened before they arrived. ---
        vm.prank(investor2);
        uint256 investor2Shares = vault.deposit(500e18, investor2);
        uint256 impliedPPS = (500e18 * 1e18) / investor2Shares;
        assertApproxEqRel(impliedPPS, ppsAfterFirstHarvest, 0.01e18); // within 1%, allowing for virtual-share rounding

        // --- Price move down: satellite $8 -> $6 (partial giveback, still above genesis cost). ---
        ftso.setPrice(FEED_SAT, 6e18, uint64(block.timestamp));
        vault.harvest();
        // A loss/drawdown must never mint a fee.
        assertEq(vault.balanceOf(treasury), treasuryAfterFirstHarvest, "no fee ever charged on a loss");
        assertEq(vault.balanceOf(strategistPayout), strategistAfterFirstHarvest, "no fee ever charged on a loss");
        assertEq(vault.highWaterMark(), hwmAfterFirstHarvest, "high-water mark must not move down");

        // --- Recovery + new all-time high: satellite $6 -> $12. ---
        ftso.setPrice(FEED_SAT, 12e18, uint64(block.timestamp));
        vault.harvest();

        uint256 hwmAfterSecondHarvest = vault.highWaterMark();
        assertGt(hwmAfterSecondHarvest, hwmAfterFirstHarvest, "second harvest must set a new high");
        uint256 treasuryAfterSecondHarvest = vault.balanceOf(treasury);
        uint256 strategistAfterSecondHarvest = vault.balanceOf(strategistPayout);
        assertGt(treasuryAfterSecondHarvest, treasuryAfterFirstHarvest);
        assertGt(strategistAfterSecondHarvest, strategistAfterFirstHarvest);

        // --- Withdrawals: both investors redeem everything; zero withdrawal fee, nothing extra
        // computed at redemption time (fees were already priced in via dilution at each harvest). ---
        uint256 investor1SharesBefore = vault.balanceOf(investor1);
        vm.prank(investor1);
        uint256 investor1Assets = vault.redeem(investor1SharesBefore, investor1, investor1);
        assertGt(investor1Assets, 1_000e18, "investor1 must be in profit overall");

        vm.prank(investor2);
        uint256 investor2Assets = vault.redeem(investor2Shares, investor2, investor2);
        // Investor2 bought in post-first-harvest and rode the dip + second harvest; should be at
        // least roughly flat to slightly up given the net satellite price move from $8 -> $12.
        assertGt(investor2Assets, 400e18);

        // --- Final reconciliation: only the fee recipients hold shares now. ---
        assertEq(vault.balanceOf(investor1), 0);
        assertEq(vault.balanceOf(investor2), 0);
        assertEq(vault.totalSupply(), vault.balanceOf(treasury) + vault.balanceOf(strategistPayout));
        assertGt(vault.totalAssets(), 0, "remaining NAV must back the fee recipients' shares");
        assertTrue(ledger.verifyChain(), "hash chain must remain unbroken through the whole lifecycle");
    }
}
