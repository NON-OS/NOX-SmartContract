// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {FeeSwapErrors} from "../../../contracts/marketplace/revenue/FeeSwapErrors.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";
import {MockSwapRouter, MockBondingToken, MockAppTokenFactory} from "./Mocks.sol";

contract FeeSwapAllowlistTest is FeeSwapBase {
    function test_revertsWhenTargetNotApproved() public {
        MockSwapRouter rogue = new MockSwapRouter(address(nox), 100e18);
        SwapParams memory p = SwapParams({
            inputToken: address(0), amountIn: 1 ether,
            target: address(rogue),
            data: abi.encodeCall(MockSwapRouter.buyTokenWithEth, (user, 0)),
            outputToken: address(nox), minOut: 0,
            receiver: user, routeId: ROUTE_V2_ETH_NOX
        });
        vm.expectRevert(abi.encodeWithSelector(FeeSwapErrors.TargetNotApproved.selector, address(rogue)));
        vm.prank(user); router.swap{value: 1 ether}(p);
    }

    function test_setTargetApprovedUnauthorizedReverts() public {
        bytes32 role = router.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        vm.prank(attacker); router.setTargetApproved(address(0xDEAD), true);
    }

    function test_setTargetApprovedZeroRejected() public {
        vm.prank(configSafe);
        vm.expectRevert(FeeSwapErrors.ZeroAddress.selector);
        router.setTargetApproved(address(0), true);
    }

    function test_canDisableTarget() public {
        vm.prank(configSafe); router.setTargetApproved(address(target), false);
        assertFalse(router.approvedTarget(address(target)));
        SwapParams memory p = _ethToTokenParams(1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(FeeSwapErrors.TargetNotApproved.selector, address(target)));
        vm.prank(user); router.swap{value: 1 ether}(p);
    }

    function test_appTokenFactoryDynamicallyApproves() public {
        MockAppTokenFactory factory = new MockAppTokenFactory();
        MockBondingToken bond = new MockBondingToken(address(nox), 50e18);
        factory.setKnown(address(bond), true);

        vm.prank(configSafe); router.setAppTokenFactory(address(factory));
        assertTrue(router.isApprovedTarget(address(bond)));
        assertFalse(router.isApprovedTarget(address(0xCAFE)));
    }

    function test_appTokenFactoryNonContractReturnsFalse() public {
        vm.prank(configSafe); router.setAppTokenFactory(address(0x1234));
        assertFalse(router.isApprovedTarget(address(0xCAFE)));
    }

    function test_appTokenFactoryUnsetReturnsFalse() public {
        assertFalse(router.isApprovedTarget(address(0xCAFE)));
    }
}
