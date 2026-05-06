// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {FeeSwapErrors} from "../../../contracts/marketplace/revenue/FeeSwapErrors.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";
import {MockSwapRouter} from "./Mocks.sol";

contract FeeSwapSwapTest is FeeSwapBase {
    function test_ethToNox_zeroFee() public {
        vm.prank(configSafe); router.setFeeBps(0);
        SwapParams memory p = _ethToTokenParams(1 ether, 99e18);
        vm.prank(user); router.swap{value: 1 ether}(p);
        assertEq(treasurySafe.balance, 0);
        assertEq(nox.balanceOf(user), 100e18);
    }

    function test_ethToNox_10bps() public {
        SwapParams memory p = _ethToTokenParams(1 ether, 99.9e18);
        vm.prank(user); router.swap{value: 1 ether}(p);
        assertEq(treasurySafe.balance, 0.001 ether);
        assertEq(nox.balanceOf(user), 99.9e18);
    }

    function test_ethToNox_revertsOnMinOut() public {
        SwapParams memory p = _ethToTokenParams(1 ether, 100e18);
        vm.expectRevert();
        vm.prank(user); router.swap{value: 1 ether}(p);
    }

    function test_ethToNox_revertsZeroValue() public {
        SwapParams memory p = _ethToTokenParams(1 ether, 0);
        vm.expectRevert(FeeSwapErrors.NotPayable.selector);
        vm.prank(user); router.swap{value: 0}(p);
    }

    function test_ethToNox_revertsValueMismatch() public {
        SwapParams memory p = _ethToTokenParams(1 ether, 0);
        vm.expectRevert(FeeSwapErrors.NotPayable.selector);
        vm.prank(user); router.swap{value: 0.5 ether}(p);
    }

    function test_ethToNox_revertsZeroAmount() public {
        SwapParams memory p = _ethToTokenParams(0, 0);
        vm.expectRevert(FeeSwapErrors.ZeroAmount.selector);
        vm.prank(user); router.swap{value: 0}(p);
    }

    function test_ethToNox_revertsTargetReverts() public {
        target.setFailNext(true);
        SwapParams memory p = _ethToTokenParams(1 ether, 0);
        vm.expectRevert();
        vm.prank(user); router.swap{value: 1 ether}(p);
    }

    function test_postFeeMinOut_exact() public {
        SwapParams memory p = _ethToTokenParams(10 ether, 999e18);
        vm.prank(user); router.swap{value: 10 ether}(p);
        assertEq(nox.balanceOf(user), 999e18);

        SwapParams memory p2 = _ethToTokenParams(10 ether, 999e18 + 1);
        vm.expectRevert();
        vm.prank(user); router.swap{value: 10 ether}(p2);
    }

    function test_noxToEth_10bps() public {
        MockSwapRouter sell = new MockSwapRouter(address(nox), 1e16);
        vm.deal(address(sell), 100 ether);
        vm.prank(configSafe); router.setTargetApproved(address(sell), true);

        nox.mint(user, 1000e18);
        vm.prank(user); nox.approve(address(router), 1000e18);

        SwapParams memory p = SwapParams({
            inputToken: address(nox), amountIn: 1000e18,
            target: address(sell),
            data: abi.encodeCall(MockSwapRouter.sellTokenForEth, (999e18, user, 0)),
            outputToken: address(0), minOut: 0,
            receiver: user, routeId: ROUTE_V2_NOX_ETH
        });

        uint256 ethBefore = user.balance;
        vm.prank(user); router.swap(p);

        assertEq(nox.balanceOf(treasurySafe), 1e18);
        assertEq(user.balance - ethBefore, 9.99 ether);
    }
}
