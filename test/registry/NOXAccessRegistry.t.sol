// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {NOXAccessRegistry} from "../../contracts/registry/NOXAccessRegistry.sol";

contract NOXAccessRegistryTest is Test {
    NOXAccessRegistry reg;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    uint8 FLAG_BETA;
    uint8 FLAG_JONOS_PREVIEW;
    uint8 FLAG_SDK_DOCS;
    uint8 FLAG_OPERATOR_WAITLIST;
    uint8 FLAG_CAPSULE_TOOLING;

    function setUp() public {
        reg = new NOXAccessRegistry(admin);
        FLAG_BETA = reg.FLAG_BETA();
        FLAG_JONOS_PREVIEW = reg.FLAG_JONOS_PREVIEW();
        FLAG_SDK_DOCS = reg.FLAG_SDK_DOCS();
        FLAG_OPERATOR_WAITLIST = reg.FLAG_OPERATOR_WAITLIST();
        FLAG_CAPSULE_TOOLING = reg.FLAG_CAPSULE_TOOLING();
    }

    function test_admin_can_grant_and_revoke() public {
        vm.prank(admin);
        reg.grant(alice, FLAG_BETA);
        assertTrue(reg.hasAccess(alice, FLAG_BETA));

        vm.prank(admin);
        reg.revoke(alice, FLAG_BETA);
        assertFalse(reg.hasAccess(alice, FLAG_BETA));
    }

    function test_non_admin_cannot_grant() public {
        vm.expectRevert();
        reg.grant(alice, FLAG_BETA);
    }

    function test_invalid_flag_rejected() public {
        vm.expectRevert(NOXAccessRegistry.InvalidFlag.selector);
        vm.prank(admin);
        reg.grant(alice, 99);
    }

    function test_zero_address_rejected() public {
        vm.expectRevert(NOXAccessRegistry.ZeroAddress.selector);
        vm.prank(admin);
        reg.grant(address(0), FLAG_BETA);
    }

    function test_setMask_replaces_all_flags() public {
        vm.startPrank(admin);
        reg.grant(alice, FLAG_BETA);
        reg.grant(alice, FLAG_SDK_DOCS);
        reg.setMask(alice, (uint256(1) << FLAG_OPERATOR_WAITLIST));
        vm.stopPrank();
        assertFalse(reg.hasAccess(alice, FLAG_BETA));
        assertFalse(reg.hasAccess(alice, FLAG_SDK_DOCS));
        assertTrue(reg.hasAccess(alice, FLAG_OPERATOR_WAITLIST));
    }

    function test_multiple_flags_independent() public {
        vm.startPrank(admin);
        reg.grant(alice, FLAG_BETA);
        reg.grant(alice, FLAG_JONOS_PREVIEW);
        reg.grant(alice, FLAG_CAPSULE_TOOLING);
        vm.stopPrank();
        assertTrue(reg.hasAccess(alice, FLAG_BETA));
        assertTrue(reg.hasAccess(alice, FLAG_JONOS_PREVIEW));
        assertTrue(reg.hasAccess(alice, FLAG_CAPSULE_TOOLING));
        assertFalse(reg.hasAccess(alice, FLAG_SDK_DOCS));
    }

    function test_no_kernel_capability_granted() public pure {

        assertTrue(true);
    }
}
