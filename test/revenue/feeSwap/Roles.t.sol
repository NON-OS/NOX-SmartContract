// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {FeeSwapErrors} from "../../../contracts/marketplace/revenue/FeeSwapErrors.sol";

contract FeeSwapRolesTest is FeeSwapBase {
    function test_setFeeBpsUnauthorized() public {
        bytes32 role = router.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        vm.prank(attacker); router.setFeeBps(5);
    }

    function test_setFeeRecipientUnauthorized() public {
        bytes32 role = router.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        vm.prank(attacker); router.setFeeRecipient(attacker);
    }

    function test_setPausedUnauthorized() public {
        bytes32 role = router.PAUSER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        vm.prank(attacker); router.setPaused(true);
    }

    function test_capEnforced() public {
        vm.prank(configSafe);
        vm.expectRevert(FeeSwapErrors.FeeExceedsCap.selector);
        router.setFeeBps(101);
    }

    function test_atCapAllowed() public {
        vm.prank(configSafe); router.setFeeBps(100);
        assertEq(router.feeBps(), 100);
    }

    function test_zeroRecipientRejected() public {
        vm.prank(configSafe);
        vm.expectRevert(FeeSwapErrors.ZeroFeeRecipient.selector);
        router.setFeeRecipient(address(0));
    }

    function test_configCanRotateRecipient() public {
        vm.prank(configSafe); router.setFeeRecipient(address(0xFEE2));
        assertEq(router.feeRecipient(), address(0xFEE2));
    }

    function test_configCanRotateFeeBps() public {
        vm.prank(configSafe); router.setFeeBps(50);
        assertEq(router.feeBps(), 50);
    }
}
