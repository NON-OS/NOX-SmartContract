// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NONOS_NOX_MAINNET_V2_1} from "../../contracts/token/NOXTokenV2_1.sol";
import {MockPair, MockRouter, MockFactory, RevertOnReceive, ToggleReceive} from "./UniMocks.sol";

contract NOXTokenV2_1Test is Test {
    NONOS_NOX_MAINNET_V2_1 nox;
    MockPair pair;
    MockRouter router;
    MockFactory factory;
    address weth;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dev = makeAddr("dev");
    address staking = makeAddr("staking");
    address dao = makeAddr("dao");
    address liq = makeAddr("liq");
    address cex = makeAddr("cex");
    address contrib = makeAddr("contrib");
    address nfts = makeAddr("nfts");
    address mkt = makeAddr("mkt");
    address fallbackR = makeAddr("fallbackR");

    function setUp() public {
        weth = makeAddr("weth");
        vm.warp(1_700_000_000);
        vm.deal(admin, 1_000 ether);
        vm.startPrank(admin);

        NONOS_NOX_MAINNET_V2_1 impl = new NONOS_NOX_MAINNET_V2_1();
        bytes memory init = abi.encodeCall(impl.initialize, (admin, dev, staking, dao, liq, cex, contrib, nfts, mkt));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        nox = NONOS_NOX_MAINNET_V2_1(payable(address(proxy)));

        pair = new MockPair();
        factory = new MockFactory();
        router = new MockRouter{value: 100 ether}(weth, address(factory));
        factory.setPair(address(nox), weth, address(pair));
        pair.setToken0(address(nox));
        pair.setReserves(uint112(1_000_000e18), uint112(1_000 ether));

        nox.initializeV2(address(router), 1_000e18, 100);

        nox.reinitV21(50_000e18, fallbackR);

        nox.setPair(address(pair), true);

        nox.setGuards(false, true, true, 50, 400, 20);

        nox.transfer(address(pair), 500_000e18);

        vm.stopPrank();
    }

    function test_freshDeploy_default_tax_is_2_5_percent() public view {
        (uint16 buyBps, uint16 sellBps, uint16 transferBps,,,,) = nox.fees();
        assertEq(buyBps, 250);
        assertEq(sellBps, 250);
        assertEq(transferBps, 0);
    }

    function test_buy_charges_2_5_percent_of_gross() public {
        uint256 buyAmount = 1_000e18;
        uint256 expectedFee = (buyAmount * 250) / 10_000;
        uint256 expectedReceived = buyAmount - expectedFee;

        address buyer = makeAddr("buyer");
        vm.prank(address(pair));
        nox.transfer(buyer, buyAmount);

        assertEq(nox.balanceOf(buyer), expectedReceived);
    }

    function test_sell_charges_2_5_percent_of_gross() public {
        uint256 sellAmount = 1_000e18;
        uint256 expectedFee = (sellAmount * 250) / 10_000;

        vm.prank(admin);
        nox.transfer(alice, sellAmount);

        vm.prank(alice);
        nox.transfer(address(pair), sellAmount);

        assertEq(nox.balanceOf(address(pair)), 500_000e18 + sellAmount - expectedFee);
    }

    function test_autoSwap_chunk_caps_swap_amount() public {
        vm.prank(admin);
        nox.setMaxAutoSwapChunk(2_000e18);

        deal(address(nox), address(nox), 5_000e18, true);
        router.setEthToReturn(10 ether);

        vm.prank(admin);
        nox.triggerAutoSwap();

        assertEq(nox.balanceOf(address(nox)), 3_000e18);
    }

    function test_autoSwap_quotes_amountOutMin_from_reserves() public {
        deal(address(nox), address(nox), 1_000e18, true);
        router.setEthToReturn(0.5 ether);

        vm.recordLogs();
        vm.prank(admin);
        nox.triggerAutoSwap();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawFailed;
        bytes32 sig = keccak256("AutoSwapFailed(uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) sawFailed = true;
        }
        assertTrue(sawFailed);
        assertEq(nox.allowance(address(nox), address(router)), 0);
    }

    function test_autoSwap_router_revert_does_not_revert_outer_tx() public {
        deal(address(nox), address(nox), 1_000e18, true);
        router.setRevert(true);
        vm.prank(admin);
        nox.triggerAutoSwap();
        assertEq(nox.allowance(address(nox), address(router)), 0);
    }

    function test_failedEth_accrues_per_recipient() public {
        RevertOnReceive bad = new RevertOnReceive();
        vm.prank(admin);
        nox.setRecipients(dev, staking, dao, address(bad));

        deal(address(nox), address(nox), 1_000e18, true);
        router.setEthToReturn(1 ether);

        vm.prank(admin);
        nox.triggerAutoSwap();

        uint256 owedToBad = nox.failedEth(address(bad));
        assertGt(owedToBad, 0);
        assertLt(owedToBad, 1 ether);
        assertEq(nox.totalFailedEth(), owedToBad);
    }

    function test_claimFailedEth_pays_recipient_after_unblock() public {
        ToggleReceive recipient = new ToggleReceive();
        vm.prank(admin);
        nox.setRecipients(dev, staking, dao, address(recipient));

        deal(address(nox), address(nox), 1_000e18, true);
        router.setEthToReturn(1 ether);

        vm.prank(admin);
        nox.triggerAutoSwap();

        uint256 owed = nox.failedEth(address(recipient));
        assertGt(owed, 0);

        recipient.flip();
        recipient.callClaim(address(nox));

        assertEq(nox.failedEth(address(recipient)), 0);
        assertEq(nox.totalFailedEth(), 0);
        assertEq(address(recipient).balance, owed);
    }

    function test_rescueETH_cannot_drain_failedEth_reserve() public {
        RevertOnReceive bad = new RevertOnReceive();
        vm.prank(admin);
        nox.setRecipients(dev, staking, dao, address(bad));

        deal(address(nox), address(nox), 1_000e18, true);
        router.setEthToReturn(1 ether);

        vm.prank(admin);
        nox.triggerAutoSwap();

        uint256 owed = nox.failedEth(address(bad));
        assertGt(owed, 0);
        assertEq(nox.totalFailedEth(), owed);

        vm.expectRevert(bytes("reserved"));
        vm.prank(admin);
        nox.rescueETH(fallbackR, 1);
    }

    function test_rescueETH_explicit_amount_only() public {
        vm.deal(address(nox), 5 ether);
        vm.prank(admin);
        nox.rescueETH(fallbackR, 2 ether);
        assertEq(fallbackR.balance, 2 ether);
        assertEq(address(nox).balance, 3 ether);
    }

    function test_setPair_grants_limitsExempt_without_feeExempt() public {
        address newPair = address(new MockPair());
        vm.prank(admin);
        nox.setPair(newPair, true);
        assertTrue(nox.limitsExempt(newPair));
        assertFalse(nox.feeExempt(newPair));
    }

    function test_setPair_disable_canonical_pair_reverts() public {
        vm.expectRevert(bytes("main-pair"));
        vm.prank(admin);
        nox.setPair(address(pair), false);
    }

    function test_setPair_disable_non_canonical_pair_succeeds() public {
        address other = address(new MockPair());
        vm.startPrank(admin);
        nox.setPair(other, true);
        nox.setPair(other, false);
        vm.stopPrank();
        assertFalse(nox.isPair(other));
        address[] memory list = nox.lpPairs();
        for (uint256 i; i < list.length; ++i) {
            assertTrue(list[i] != other);
        }
    }

    function test_zero_recipient_accrues_to_fallback_and_emits_with_fallback() public {
        vm.store(address(nox), bytes32(uint256(7)), bytes32(uint256(0)));
        assertEq(nox.liquidityCollector(), address(0));

        deal(address(nox), address(nox), 1_000e18, true);
        router.setEthToReturn(1 ether);

        vm.recordLogs();
        vm.prank(admin);
        nox.triggerAutoSwap();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("AutoSwapForwardFailed(address,uint256)");
        bool sawWithFallback;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig && logs[i].topics.length >= 2) {
                address logged = address(uint160(uint256(logs[i].topics[1])));
                if (logged == fallbackR) sawWithFallback = true;
            }
        }
        assertTrue(sawWithFallback);
        assertGt(nox.failedEth(fallbackR), 0);
        assertEq(nox.failedEth(fallbackR), nox.totalFailedEth());
    }

    function test_setPair_off_then_on_no_duplicate_in_list() public {
        address p = address(new MockPair());
        vm.startPrank(admin);
        nox.setPair(p, true);
        nox.setPair(p, false);
        nox.setPair(p, true);
        vm.stopPrank();
        address[] memory list = nox.lpPairs();
        uint256 occurrences;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == p) occurrences++;
        }
        assertEq(occurrences, 1);
    }

    function test_sameBlockGuard_does_not_block_pair_as_from() public {
        vm.prank(admin);
        nox.setGuards(true, true, true, 50, 400, 0);

        vm.prank(address(pair));
        nox.transfer(alice, 100e18);
        vm.prank(address(pair));
        nox.transfer(bob, 100e18);
    }

    function test_cannot_unset_self_feeExempt() public {
        vm.expectRevert(bytes("self-fee"));
        vm.prank(admin);
        nox.setExemptions(address(nox), false, true);
    }

    function test_setDeflationParams_rejects_combo_breaking_sum() public {
        vm.prank(admin);
        nox.setFees(1000, 1000, 0, 1000, 4000, 2000, 3000);
        vm.expectRevert(bytes("c"));
        vm.prank(admin);
        nox.setDeflationParams(900, 0, 0);
    }

    function test_setFees_rejects_individual_over_cap() public {
        vm.expectRevert(bytes("a"));
        vm.prank(admin);
        nox.setFees(1500, 250, 0, 1000, 4000, 2000, 3000);
    }

    function test_unauthorised_upgrade_rejected() public {
        NONOS_NOX_MAINNET_V2_1 newImpl = new NONOS_NOX_MAINNET_V2_1();
        vm.prank(alice);
        vm.expectRevert();
        nox.upgradeToAndCall(address(newImpl), "");
    }

    function test_authorised_upgrade_succeeds() public {
        NONOS_NOX_MAINNET_V2_1 newImpl = new NONOS_NOX_MAINNET_V2_1();
        vm.prank(admin);
        nox.upgradeToAndCall(address(newImpl), "");
    }

    function test_reinitV21_cannot_be_replayed() public {
        vm.prank(admin);
        vm.expectRevert();
        nox.reinitV21(123e18, fallbackR);
    }

    function test_reinitV21_role_gated() public {
        vm.startPrank(admin);
        NONOS_NOX_MAINNET_V2_1 fresh = new NONOS_NOX_MAINNET_V2_1();
        bytes memory init = abi.encodeCall(fresh.initialize, (admin, dev, staking, dao, liq, cex, contrib, nfts, mkt));
        ERC1967Proxy p = new ERC1967Proxy(address(fresh), init);
        NONOS_NOX_MAINNET_V2_1 t = NONOS_NOX_MAINNET_V2_1(payable(address(p)));
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        t.reinitV21(1, fallbackR);
    }

    function test_blacklist_blocks_transfer() public {
        vm.prank(admin);
        nox.setBlacklist(alice, true);
        vm.expectRevert(bytes("g"));
        vm.prank(admin);
        nox.transfer(alice, 1);
    }

    function test_pause_blocks_transfer() public {
        vm.prank(admin);
        nox.pause();
        vm.expectRevert();
        vm.prank(admin);
        nox.transfer(alice, 1);
    }

    function test_emergencyStop_blocks_transfer() public {
        vm.prank(admin);
        nox.setEmergencyStop(true);
        vm.expectRevert(bytes("f"));
        vm.prank(admin);
        nox.transfer(alice, 1);
    }
}
