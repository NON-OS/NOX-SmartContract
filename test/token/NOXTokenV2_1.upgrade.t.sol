// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NONOS_NOX_MAINNET_V2_1 as V21} from "../../contracts/token/NOXTokenV2_1.sol";
import {NONOS_NOX_MAINNET_V2 as V2} from "../../contracts/token/NOXTokenV2.sol";
import {MockPair, MockRouter, MockFactory} from "./UniMocks.sol";

contract NOXUpgradeReplay is Test {
    address admin;
    address alice;
    address fb;
    address weth;

    V2 nox;
    MockPair pair;
    MockFactory fac;
    MockRouter rt;

    struct Snap {
        uint256 totalSupply;
        uint256 totalBurned;
        uint256 alice;
        bool pairFlag;
        uint256 threshold;
        uint16 slippage;
        bool enabled;
        bool v2Init;
    }

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        fb = makeAddr("fallback");
        weth = makeAddr("weth");
        vm.deal(admin, 1_000 ether);

        _deployV2();
        _wireMocks();
        _runV2Init();
        _seedState();
    }

    function test_state_preserved_across_upgrade_then_tax_applied() public {
        _assertV2DefaultsAreOldTax();

        Snap memory snap = _snapshot();

        V21 nox21 = _upgrade();

        _assertSnapshotPreserved(nox21, snap);
        _assertV21Initialised(nox21);
        _assertReinitDoesNotChangeFees(nox21);

        _applyProductionFees(nox21);
        _assertProductionFees(nox21);
    }

    function _deployV2() internal {
        vm.startPrank(admin);
        V2 implV2 = new V2();
        bytes memory init = _initData(admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implV2), init);
        nox = V2(payable(address(proxy)));
    }

    function _initData(address a) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,address,address,address)",
            a,
            a,
            a,
            a,
            a,
            a,
            a,
            a,
            a
        );
    }

    function _wireMocks() internal {
        pair = new MockPair();
        fac = new MockFactory();
        rt = new MockRouter{value: 100 ether}(weth, address(fac));
        fac.setPair(address(nox), weth, address(pair));
        pair.setToken0(address(nox));
        pair.setReserves(uint112(1_000_000e18), uint112(1_000 ether));
    }

    function _runV2Init() internal {
        nox.initializeV2(address(rt), 1_000e18, 100);
    }

    function _seedState() internal {
        nox.transfer(alice, 1_234e18);
        nox.setPair(address(pair), true);
        nox.setBlacklist(alice, false);
        nox.setGuards(false, true, true, 50, 400, 20);
        vm.stopPrank();
    }

    function _assertV2DefaultsAreOldTax() internal view {
        (uint16 buy, uint16 sell,,,,,) = nox.fees();
        assertEq(buy, 200);
        assertEq(sell, 200);
    }

    function _snapshot() internal view returns (Snap memory s) {
        s.totalSupply = nox.totalSupply();
        s.totalBurned = nox.totalBurned();
        s.alice = nox.balanceOf(alice);
        s.pairFlag = nox.isPair(address(pair));
        s.threshold = nox.autoSwapThreshold();
        s.slippage = nox.autoSwapSlippageBps();
        s.enabled = nox.autoSwapEnabled();
        s.v2Init = nox.v2Initialized();
    }

    function _upgrade() internal returns (V21) {
        vm.startPrank(admin);
        V21 implV21 = new V21();
        bytes memory call = abi.encodeCall(V21.reinitV21, (50_000e18, fb));
        nox.upgradeToAndCall(address(implV21), call);
        vm.stopPrank();
        return V21(payable(address(nox)));
    }

    function _assertSnapshotPreserved(V21 nox21, Snap memory snap) internal view {
        assertEq(nox21.totalSupply(), snap.totalSupply);
        assertEq(nox21.totalBurned(), snap.totalBurned);
        assertEq(nox21.balanceOf(alice), snap.alice);
        assertEq(nox21.isPair(address(pair)), snap.pairFlag);
        assertEq(nox21.autoSwapThreshold(), snap.threshold);
        assertEq(nox21.autoSwapSlippageBps(), snap.slippage);
        assertEq(nox21.autoSwapEnabled(), snap.enabled);
        assertEq(nox21.v2Initialized(), snap.v2Init);
    }

    function _assertV21Initialised(V21 nox21) internal view {
        assertEq(nox21.maxAutoSwapChunk(), 50_000e18);
        assertEq(nox21.ethFallbackRecipient(), fb);
        assertTrue(nox21.limitsExempt(address(pair)));
        assertFalse(nox21.feeExempt(address(pair)));
    }

    function _assertReinitDoesNotChangeFees(V21 nox21) internal view {
        (uint16 buy, uint16 sell,,,,,) = nox21.fees();
        assertEq(buy, 200);
        assertEq(sell, 200);
    }

    function _applyProductionFees(V21 nox21) internal {
        vm.prank(admin);
        nox21.setFees(250, 250, 0, 1000, 4000, 2000, 3000);
    }

    function _assertProductionFees(V21 nox21) internal view {
        (uint16 buy, uint16 sell, uint16 t,,,,) = nox21.fees();
        assertEq(buy, 250);
        assertEq(sell, 250);
        assertEq(t, 0);
    }
}
