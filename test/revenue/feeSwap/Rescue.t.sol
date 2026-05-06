// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {FeeSwapErrors} from "../../../contracts/marketplace/revenue/FeeSwapErrors.sol";

contract FeeSwapRescueTest is FeeSwapBase {
    function test_rescueETHByConfig() public {
        vm.deal(address(router), 1 ether);
        vm.prank(configSafe); router.rescueETH(address(0xBEEF), 1 ether);
        assertEq(address(0xBEEF).balance, 1 ether);
    }

    function test_rescueETHUnauthorized() public {
        vm.deal(address(router), 1 ether);
        bytes32 role = router.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        vm.prank(attacker); router.rescueETH(attacker, 1 ether);
    }

    function test_rescueERC20ByConfig() public {
        nox.mint(address(router), 100e18);
        vm.prank(configSafe); router.rescueERC20(address(nox), address(0xBEEF), 100e18);
        assertEq(nox.balanceOf(address(0xBEEF)), 100e18);
    }

    function test_rescueERC20Unauthorized() public {
        nox.mint(address(router), 100e18);
        bytes32 role = router.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        vm.prank(attacker); router.rescueERC20(address(nox), attacker, 100e18);
    }

    function test_rescueZeroChecks() public {
        vm.deal(address(router), 1 ether);
        vm.prank(configSafe);
        vm.expectRevert(FeeSwapErrors.ZeroAddress.selector);
        router.rescueETH(address(0), 1 ether);

        vm.prank(configSafe);
        vm.expectRevert(FeeSwapErrors.ZeroAmount.selector);
        router.rescueETH(address(0xBEEF), 0);
    }
}
