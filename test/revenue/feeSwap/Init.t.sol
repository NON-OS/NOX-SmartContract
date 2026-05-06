// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";

contract FeeSwapInitTest is FeeSwapBase {
    function test_initialState() public view {
        assertEq(router.feeBps(), 10);
        assertEq(router.feeRecipient(), treasurySafe);
        assertEq(router.MAX_FEE_BPS(), 100);
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(router.hasRole(router.CONFIG_ROLE(), configSafe));
        assertTrue(router.hasRole(router.PAUSER_ROLE(), pauserSafe));
        assertTrue(router.hasRole(router.UPGRADER_ROLE(), upgrader));
        assertFalse(router.paused());
    }

    function test_initializerCannotRerun() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        router.initialize(admin, configSafe, pauserSafe, upgrader, treasurySafe, 10);
    }

    function test_rejectsZeroRecipient() public {
        FeeSwapRouter impl = new FeeSwapRouter();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeSwapRouter.initialize, (admin, configSafe, pauserSafe, upgrader, address(0), 10))
        );
    }

    function test_rejectsFeeAboveCap() public {
        FeeSwapRouter impl = new FeeSwapRouter();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeSwapRouter.initialize, (admin, configSafe, pauserSafe, upgrader, treasurySafe, 101))
        );
    }
}
