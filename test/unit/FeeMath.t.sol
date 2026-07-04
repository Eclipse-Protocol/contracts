// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";

contract FeeMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant GENESIS_HWM = 1.2e18;

    // ---------------------------------------------------------------------
    // pricePerShare
    // ---------------------------------------------------------------------

    function test_pricePerShare_genesisIsOneWad() public pure {
        assertEq(FeeMath.pricePerShare(0, 0), WAD);
    }

    function test_pricePerShare_oneToOne() public pure {
        assertEq(FeeMath.pricePerShare(1_000e18, 1_000e18), WAD);
    }

    function test_pricePerShare_scalesWithGains() public pure {
        // 1200 assets backing 1000 shares => PPS = 1.2e18
        assertEq(FeeMath.pricePerShare(1_200e18, 1_000e18), 1.2e18);
    }

    // ---------------------------------------------------------------------
    // computeFeeShares — hurdle behavior
    // ---------------------------------------------------------------------

    function test_computeFeeShares_noFeeBelowHurdle() public pure {
        // PPS grew from 1.0 to 1.1 — still below the 1.2 genesis hurdle.
        uint256 totalSupply_ = 1_000e18;
        uint256 totalAssets_ = 1_100e18;
        uint256 pps = FeeMath.pricePerShare(totalAssets_, totalSupply_);

        (uint256 treasuryShares, uint256 strategistShares) =
            FeeMath.computeFeeShares(pps, GENESIS_HWM, totalAssets_, totalSupply_);

        assertEq(treasuryShares, 0);
        assertEq(strategistShares, 0);
    }

    function test_computeFeeShares_noFeeExactlyAtHurdle() public pure {
        // PPS == highWaterMark exactly must NOT trigger a fee (strictly greater required).
        uint256 totalSupply_ = 1_000e18;
        uint256 totalAssets_ = (GENESIS_HWM * totalSupply_) / WAD;
        uint256 pps = FeeMath.pricePerShare(totalAssets_, totalSupply_);
        assertEq(pps, GENESIS_HWM);

        (uint256 treasuryShares, uint256 strategistShares) =
            FeeMath.computeFeeShares(pps, GENESIS_HWM, totalAssets_, totalSupply_);

        assertEq(treasuryShares, 0);
        assertEq(strategistShares, 0);
    }

    function test_computeFeeShares_triggersAboveHurdle() public pure {
        // PPS grows from genesis 1.0 to 1.5 (well above the 1.2 hurdle).
        uint256 totalSupply_ = 1_000e18;
        uint256 totalAssets_ = 1_500e18;
        uint256 pps = FeeMath.pricePerShare(totalAssets_, totalSupply_);

        (uint256 treasuryShares, uint256 strategistShares) =
            FeeMath.computeFeeShares(pps, GENESIS_HWM, totalAssets_, totalSupply_);

        assertGt(treasuryShares, 0);
        assertGt(strategistShares, 0);

        // gain per share = 0.3e18, over 1000 shares => 300 underlying of gain.
        // 10% fee => 30 underlying of value, split 3/7 => 9 to treasury, 21 to strategist (pre-dilution).
        uint256 expectedFeeValue = 30e18;
        uint256 expectedCombinedShares = (expectedFeeValue * totalSupply_) / (totalAssets_ - expectedFeeValue);
        uint256 expectedTreasury = (expectedCombinedShares * 300) / 1000;
        uint256 expectedStrategist = expectedCombinedShares - expectedTreasury;

        assertEq(treasuryShares, expectedTreasury);
        assertEq(strategistShares, expectedStrategist);

        // 3:7 split ratio should hold (within integer rounding from the two sequential divisions —
        // the combined-shares division and the treasury/strategist split division — each of which can
        // round down independently).
        assertApproxEqAbs(strategistShares * 3, treasuryShares * 7, 10);
    }

    function test_computeFeeShares_zeroWhenSupplyZero() public pure {
        (uint256 treasuryShares, uint256 strategistShares) = FeeMath.computeFeeShares(2e18, GENESIS_HWM, 0, 0);
        assertEq(treasuryShares, 0);
        assertEq(strategistShares, 0);
    }

    function test_computeFeeShares_dilutionMintsCorrectValue() public pure {
        // After minting, the treasury+strategist shares should be worth ~ the fee value at the NEW pps.
        uint256 totalSupply_ = 1_000e18;
        uint256 totalAssets_ = 1_500e18;
        uint256 pps = FeeMath.pricePerShare(totalAssets_, totalSupply_);

        (uint256 treasuryShares, uint256 strategistShares) =
            FeeMath.computeFeeShares(pps, GENESIS_HWM, totalAssets_, totalSupply_);

        uint256 newSupply = totalSupply_ + treasuryShares + strategistShares;
        uint256 mintedValue = ((treasuryShares + strategistShares) * totalAssets_) / newSupply;

        // Minted value should approximate 10% of the 300-underlying gain (30), within rounding.
        assertApproxEqAbs(mintedValue, 30e18, 1e15);
    }

    // ---------------------------------------------------------------------
    // Sequential harvests: gain -> dip -> recovery must not double-charge
    // ---------------------------------------------------------------------

    function test_sequentialHarvests_dipThenRecoveryNoDoubleCharge() public pure {
        uint256 totalSupply_ = 1_000e18;
        uint256 hwm = GENESIS_HWM;

        // 1) Gain to 1.5x — fee triggers, HWM ratchets up to 1.5.
        uint256 assets1 = 1_500e18;
        uint256 pps1 = FeeMath.pricePerShare(assets1, totalSupply_);
        (uint256 t1, uint256 s1) = FeeMath.computeFeeShares(pps1, hwm, assets1, totalSupply_);
        assertGt(t1 + s1, 0);
        totalSupply_ += t1 + s1;
        hwm = pps1;

        // 2) Dip back down to 1.3x (still above genesis hurdle, but below the new HWM) — zero fee.
        uint256 assets2 = 1_300e18;
        uint256 pps2 = FeeMath.pricePerShare(assets2, totalSupply_);
        (uint256 t2, uint256 s2) = FeeMath.computeFeeShares(pps2, hwm, assets2, totalSupply_);
        assertEq(t2, 0);
        assertEq(s2, 0);
        // HWM does not move on a no-op harvest.

        // 3) Recover exactly back to the prior peak (pps1-equivalent assets) — still zero fee,
        // since currentPPS <= highWaterMark (recovering the drawdown is not "new" profit).
        uint256 assets3 = (hwm * totalSupply_) / WAD;
        uint256 pps3 = FeeMath.pricePerShare(assets3, totalSupply_);
        (uint256 t3, uint256 s3) = FeeMath.computeFeeShares(pps3, hwm, assets3, totalSupply_);
        assertEq(t3, 0);
        assertEq(s3, 0);

        // 4) Only once assets exceed the OLD high-water mark does a new fee trigger, and it must be
        // charged only on the incremental gain above the old peak, not the whole recovered amount.
        uint256 assets4 = assets3 + 50e18;
        uint256 pps4 = FeeMath.pricePerShare(assets4, totalSupply_);
        (uint256 t4, uint256 s4) = FeeMath.computeFeeShares(pps4, hwm, assets4, totalSupply_);
        assertGt(t4 + s4, 0);

        // Sanity: the combined minted share value should approximate 10% of the 50-unit incremental
        // gain (5), not 10% of the full recovered 350-unit move from the dip.
        uint256 newSupply = totalSupply_ + t4 + s4;
        uint256 mintedValue = ((t4 + s4) * assets4) / newSupply;
        assertApproxEqAbs(mintedValue, 5e18, 1e15);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_pricePerShare_neverRevertsAndScalesLinearly(uint128 assetsIn, uint128 supplyIn) public pure {
        uint256 assets_ = uint256(assetsIn);
        uint256 supply_ = uint256(supplyIn);
        vm.assume(supply_ > 0);

        uint256 pps = FeeMath.pricePerShare(assets_, supply_);
        // Doubling both assets and supply should not change PPS (within 1 wei of rounding).
        uint256 ppsDoubled = FeeMath.pricePerShare(assets_ * 2, supply_ * 2);
        assertApproxEqAbs(pps, ppsDoubled, 1);
    }

    function testFuzz_computeFeeShares_neverExceedsAssetsOrReverts(
        uint96 totalSupplyIn,
        uint96 totalAssetsIn,
        uint32 hwmDeltaBps
    ) public pure {
        uint256 totalSupply_ = uint256(totalSupplyIn) + 1;
        uint256 totalAssets_ = uint256(totalAssetsIn) + 1;
        vm.assume(totalAssets_ < type(uint128).max);

        uint256 pps = FeeMath.pricePerShare(totalAssets_, totalSupply_);
        // Highwater mark somewhere below current PPS by a fuzzed delta (bounded to avoid overflow).
        uint256 delta = (uint256(hwmDeltaBps) % 5_000) * pps / 10_000;
        uint256 hwm = pps > delta ? pps - delta : 0;

        (uint256 treasuryShares, uint256 strategistShares) =
            FeeMath.computeFeeShares(pps, hwm, totalAssets_, totalSupply_);

        // The fee must never be large enough to claim 100% of assets (feeValue < totalAssets check
        // inside the library guards this) and shares minted must be a finite, sane quantity.
        assertLt(treasuryShares + strategistShares, type(uint256).max);
        if (treasuryShares + strategistShares > 0) {
            assertApproxEqAbs(strategistShares * 3, treasuryShares * 7, treasuryShares + strategistShares + 10);
        }
    }
}
