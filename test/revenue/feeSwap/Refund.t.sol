// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";
import {MockSwapRouter, MockEthRefunder, MockPartialPull, MockFoTERC20} from "./Mocks.sol";

contract FeeSwapRefundTest is FeeSwapBase {
    function test_leftoverEthRefundedToPayer() public {
        MockEthRefunder ref = new MockEthRefunder(address(nox), 0.1 ether);
        vm.deal(address(ref), 1 ether);
        vm.prank(configSafe); router.setTargetApproved(address(ref), true);

        SwapParams memory p = SwapParams({
            inputToken: address(0), amountIn: 1 ether,
            target: address(ref),
            data: abi.encodeCall(MockEthRefunder.buyAndRefund, (user, 0)),
            outputToken: address(nox), minOut: 0,
            receiver: user, routeId: keccak256("eth-refund")
        });

        uint256 ethBefore = user.balance;
        vm.prank(user); router.swap{value: 1 ether}(p);
        assertEq(ethBefore - user.balance, 0.9 ether);
    }

    function test_leftoverErc20RefundedToPayer() public {
        MockPartialPull pp = new MockPartialPull(address(nox), 8000);
        vm.prank(configSafe); router.setTargetApproved(address(pp), true);
        vm.prank(configSafe); router.setFeeBps(0);

        nox.mint(user, 1000e18);
        vm.prank(user); nox.approve(address(router), 1000e18);

        SwapParams memory p = SwapParams({
            inputToken: address(nox), amountIn: 1000e18,
            target: address(pp),
            data: abi.encodeCall(MockPartialPull.partialPull, (address(router), 1000e18, user)),
            outputToken: address(nox), minOut: 0,
            receiver: user, routeId: keccak256("partial-pull")
        });

        uint256 noxBefore = nox.balanceOf(user);
        vm.prank(user); router.swap(p);
        assertEq(noxBefore - nox.balanceOf(user), 800e18);
    }

    function test_allowanceResetToZero() public {
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

        vm.prank(user); router.swap(p);
        assertEq(nox.allowance(address(router), address(sell)), 0);
    }

    function test_fotInputTakesFeeOnActualReceived() public {
        MockFoTERC20 fot = new MockFoTERC20();
        fot.mint(user, 1000e18);

        MockSwapRouter sell = new MockSwapRouter(address(fot), 1e16);
        vm.deal(address(sell), 100 ether);
        vm.prank(configSafe); router.setTargetApproved(address(sell), true);

        vm.prank(user); fot.approve(address(router), 1000e18);

        SwapParams memory p = SwapParams({
            inputToken: address(fot), amountIn: 1000e18,
            target: address(sell),
            data: abi.encodeCall(MockSwapRouter.sellTokenForEth, (uint256(940e18), user, 0)),
            outputToken: address(0), minOut: 0,
            receiver: user, routeId: keccak256("fot")
        });

        uint256 treasuryBefore = fot.balanceOf(treasurySafe);
        vm.prank(user); router.swap(p);

        uint256 fee = fot.balanceOf(treasurySafe) - treasuryBefore;
        assertApproxEqAbs(fee, 0.9025e18, 0.001e18);
    }
}
