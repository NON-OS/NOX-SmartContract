// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {FeeSwapErrors} from "../../../contracts/marketplace/revenue/FeeSwapErrors.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";

interface IUniV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external;
}

contract FeeSwapLiveProxyTest is Test {
    address constant ROUTER_PROXY = 0x09d4fDb7176ef0E20Af558e650d2dcd8D1f73d62;
    address constant V2_ROUTER    = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH         = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant NOX          = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant B33          = 0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33;

    FeeSwapRouter router;
    address user = address(0xCAFE);

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        router = FeeSwapRouter(payable(ROUTER_PROXY));
        vm.deal(user, 10 ether);
    }

    function _has() internal view returns (bool) { return address(router) != address(0); }

    function test_live_initialState() public {
        if (!_has()) { vm.skip(true); return; }
        assertEq(router.feeBps(), 10);
        assertEq(router.feeRecipient(), B33);
        assertEq(router.MAX_FEE_BPS(), 100);
        assertFalse(router.paused());
        assertTrue(router.approvedTarget(V2_ROUTER));
    }

    function test_live_ethToNox() public {
        if (!_has()) { vm.skip(true); return; }
        address[] memory path = new address[](2);
        path[0] = WETH; path[1] = NOX;
        uint256 amountIn = 0.01 ether;

        bytes memory data = abi.encodeCall(
            IUniV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens,
            (0, path, user, block.timestamp + 600)
        );
        SwapParams memory p = SwapParams({
            inputToken: address(0), amountIn: amountIn,
            target: V2_ROUTER, data: data,
            outputToken: NOX, minOut: 0,
            receiver: user, routeId: keccak256("v2:eth-nox")
        });

        uint256 noxBefore = IERC20(NOX).balanceOf(user);
        uint256 b33Before = B33.balance;

        vm.prank(user);
        router.swap{value: amountIn}(p);

        assertEq(B33.balance - b33Before, (amountIn * 10) / 10000, "B33 receives exactly 10 bps");
        assertGt(IERC20(NOX).balanceOf(user), noxBefore, "user receives NOX");
    }

    function test_live_noxToEth() public {
        if (!_has()) { vm.skip(true); return; }
        deal(NOX, user, 10000e18);
        vm.prank(user);
        IERC20(NOX).approve(ROUTER_PROXY, 10000e18);

        address[] memory path = new address[](2);
        path[0] = NOX; path[1] = WETH;
        bytes memory data = abi.encodeCall(
            IUniV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens,
            (uint256(9990e18), uint256(0), path, user, block.timestamp + 600)
        );
        SwapParams memory p = SwapParams({
            inputToken: NOX, amountIn: 10000e18,
            target: V2_ROUTER, data: data,
            outputToken: address(0), minOut: 0,
            receiver: user, routeId: keccak256("v2:nox-eth")
        });

        uint256 ethBefore = user.balance;
        uint256 b33NoxBefore = IERC20(NOX).balanceOf(B33);

        vm.prank(user);
        router.swap(p);

        assertGt(user.balance, ethBefore, "user gets ETH");
        assertGt(IERC20(NOX).balanceOf(B33) - b33NoxBefore, 0, "B33 receives NOX fee");
        assertEq(IERC20(NOX).allowance(ROUTER_PROXY, V2_ROUTER), 0, "allowance reset");
    }

    function test_live_revertsOnMinOut() public {
        if (!_has()) { vm.skip(true); return; }
        address[] memory path = new address[](2);
        path[0] = WETH; path[1] = NOX;
        bytes memory data = abi.encodeCall(
            IUniV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens,
            (0, path, user, block.timestamp + 600)
        );
        SwapParams memory p = SwapParams({
            inputToken: address(0), amountIn: 0.01 ether,
            target: V2_ROUTER, data: data,
            outputToken: NOX, minOut: type(uint256).max,
            receiver: user, routeId: keccak256("v2:eth-nox")
        });
        vm.expectRevert();
        vm.prank(user);
        router.swap{value: 0.01 ether}(p);
    }

    function test_live_revertsTargetNotApproved() public {
        if (!_has()) { vm.skip(true); return; }
        address rogue = address(0x1234567890123456789012345678901234567890);
        SwapParams memory p = SwapParams({
            inputToken: address(0), amountIn: 0.01 ether,
            target: rogue, data: hex"00",
            outputToken: NOX, minOut: 0,
            receiver: user, routeId: keccak256("rogue")
        });
        vm.expectRevert(abi.encodeWithSelector(FeeSwapErrors.TargetNotApproved.selector, rogue));
        vm.prank(user);
        router.swap{value: 0.01 ether}(p);
    }

    function test_live_revertsWhenPaused() public {
        if (!_has()) { vm.skip(true); return; }
        vm.prank(B33);
        router.setPaused(true);

        address[] memory path = new address[](2);
        path[0] = WETH; path[1] = NOX;
        bytes memory data = abi.encodeCall(
            IUniV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens,
            (0, path, user, block.timestamp + 600)
        );
        SwapParams memory p = SwapParams({
            inputToken: address(0), amountIn: 0.01 ether,
            target: V2_ROUTER, data: data,
            outputToken: NOX, minOut: 0,
            receiver: user, routeId: keccak256("v2:eth-nox")
        });
        vm.expectRevert(FeeSwapErrors.PausedError.selector);
        vm.prank(user);
        router.swap{value: 0.01 ether}(p);

        vm.prank(B33);
        router.setPaused(false);
    }
}
