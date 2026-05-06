// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingCurveLib} from "../../contracts/marketplace/libraries/BondingCurveLib.sol";
import {BondingCurveLibHarness} from "./BondingCurveLibHarness.sol";

contract BondingCurveLibTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant GRADUATION = 800_000_000 * ONE;
    uint16  constant FEE_BPS = 100;

    BondingCurveLibHarness h;

    function setUp() public {
        h = new BondingCurveLibHarness();
    }

    function test_initialPrice_isPositive() public pure {
        uint256 p = BondingCurveLib.priceAtSupply(0);
        assertGt(p, 0, "initial price must be > 0");
    }

    function test_priceMonotonic() public pure {
        uint256 a = BondingCurveLib.priceAtSupply(1_000_000 * ONE);
        uint256 b = BondingCurveLib.priceAtSupply(10_000_000 * ONE);
        uint256 c = BondingCurveLib.priceAtSupply(100_000_000 * ONE);
        assertLt(a, b);
        assertLt(b, c);
    }

    function test_reserveAtZeroIsZero() public pure {
        assertEq(BondingCurveLib.reserveAtSupply(0), 0);
    }

    function test_supplyAtReserveZeroIsZero() public pure {
        assertEq(BondingCurveLib.supplyAtReserve(0), 0);
    }

    function test_buyMonotonic() public pure {
        uint256 supply = 0;
        (uint256 t1, ) = BondingCurveLib.quoteBuy(supply, GRADUATION, 1 ether, FEE_BPS);
        supply += t1;
        (uint256 t2, ) = BondingCurveLib.quoteBuy(supply, GRADUATION, 1 ether, FEE_BPS);
        assertLt(t2, t1, "second buy gets fewer tokens (price rose)");
    }

    function test_sellMonotonic() public pure {
        uint256 supply = 0;
        (uint256 t1, ) = BondingCurveLib.quoteBuy(supply, GRADUATION, 5 ether, FEE_BPS);
        supply += t1;
        (uint256 e1, ) = BondingCurveLib.quoteSell(supply, t1 / 2, FEE_BPS);
        (uint256 e2, ) = BondingCurveLib.quoteSell(supply, t1, FEE_BPS);
        assertGt(e2, e1, "selling more gives more eth out");
    }

    function test_roundtripLosesProportionalToFee() public pure {
        uint256 supply = 0;
        uint256 ethIn = 5 ether;
        (uint256 tokens, uint256 buyFee) = BondingCurveLib.quoteBuy(supply, GRADUATION, ethIn, FEE_BPS);
        supply += tokens;
        (uint256 ethBack, uint256 sellFee) = BondingCurveLib.quoteSell(supply, tokens, FEE_BPS);

        uint256 lost = ethIn - ethBack;
        uint256 totalFees = buyFee + sellFee;
        assertLe(totalFees, lost, "lost must be at least the explicit fees");
        uint256 maxExpectedLoss = (ethIn * uint256(FEE_BPS) * 4) / 10_000;
        assertLe(lost, maxExpectedLoss, "no greater than 4x fee budget loss (rounding tolerance)");
    }

    function test_buyCapsAtGraduation() public pure {
        uint256 supply = (GRADUATION * 50) / 100;
        (uint256 tokensOut, ) = BondingCurveLib.quoteBuy(supply, GRADUATION, 100_000 ether, FEE_BPS);
        assertEq(supply + tokensOut, GRADUATION, "buy must clamp at graduation");
    }

    function test_zeroEthBuyReverts_viaHarness() public {
        vm.expectRevert(BondingCurveLib.AmountTooSmall.selector);
        h.quoteBuy(0, GRADUATION, 0, FEE_BPS);
    }

    function test_invalidFeeReverts_viaHarness() public {
        vm.expectRevert(BondingCurveLib.InvalidFee.selector);
        h.quoteBuy(0, GRADUATION, 1 ether, 10_000);
    }

    function test_zeroGraduationReverts_viaHarness() public {
        vm.expectRevert(BondingCurveLib.InvalidGraduationSupply.selector);
        h.quoteBuy(0, 0, 1 ether, FEE_BPS);
    }

    function test_sellExceedsSupplyReverts_viaHarness() public {
        vm.expectRevert(BondingCurveLib.SellExceedsSupply.selector);
        h.quoteSell(100 * ONE, 1000 * ONE, FEE_BPS);
    }

    function test_progressBps() public pure {
        assertEq(BondingCurveLib.graduationProgressBps(0, GRADUATION), 0);
        assertEq(BondingCurveLib.graduationProgressBps(GRADUATION / 2, GRADUATION), 5_000);
        assertEq(BondingCurveLib.graduationProgressBps(GRADUATION, GRADUATION), 10_000);
        assertEq(BondingCurveLib.graduationProgressBps(GRADUATION * 2, GRADUATION), 10_000);
    }

    function test_progressBpsZeroGraduationIsZero() public pure {
        assertEq(BondingCurveLib.graduationProgressBps(1_000 * ONE, 0), 0);
    }

    function testFuzz_buyWithinReasonableRange(uint96 ethIn) public pure {
        vm.assume(ethIn > 0.01 ether);
        vm.assume(ethIn < 1_000 ether);
        (uint256 tokensOut, uint256 fee) = BondingCurveLib.quoteBuy(0, GRADUATION, ethIn, FEE_BPS);
        assertGt(tokensOut, 0);
        assertLt(fee, ethIn);
        assertLe(tokensOut, GRADUATION);
    }

    function testFuzz_sellNeverExceedsReserve(uint96 ethIn) public pure {
        vm.assume(ethIn > 0.01 ether);
        vm.assume(ethIn < 100 ether);
        uint256 supply = 0;
        (uint256 tokens, uint256 buyFee) = BondingCurveLib.quoteBuy(supply, GRADUATION, ethIn, FEE_BPS);
        supply += tokens;
        (uint256 ethOut, uint256 sellFee) = BondingCurveLib.quoteSell(supply, tokens, FEE_BPS);
        uint256 reserveBudget = ethIn - buyFee + 1e9;
        assertLe(ethOut + sellFee, reserveBudget);
    }
}
