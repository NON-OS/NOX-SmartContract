// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";

interface IUniV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory);
}

contract FeeSwapForkTest is Test {
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant NOX       = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;

    address admin       = address(0xA001);
    address configSafe  = address(0xC001);
    address pauserSafe  = address(0xC002);
    address upgrader    = address(0xC003);
    address treasurySafe= address(0xD001);
    address user        = address(0xCAFE);

    FeeSwapRouter router;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }
        vm.createSelectFork(rpc);

        FeeSwapRouter impl = new FeeSwapRouter();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeSwapRouter.initialize, (admin, configSafe, pauserSafe, upgrader, treasurySafe, 10))
        );
        router = FeeSwapRouter(payable(address(proxy)));

        vm.prank(configSafe);
        router.setTargetApproved(V2_ROUTER, true);

        vm.deal(user, 10 ether);
    }

    function _hasFork() internal view returns (bool) {
        return address(router) != address(0);
    }

    function test_fork_ethToNoxOnRealUniswapV2() public {
        if (!_hasFork()) { vm.skip(true); return; }

        address[] memory path = new address[](2);
        path[0] = WETH; path[1] = NOX;
        uint256 inAmt = 0.01 ether;

        IUniV2Router r = IUniV2Router(V2_ROUTER);
        uint256[] memory quote = r.getAmountsOut(inAmt - (inAmt * 10 / 10000), path);
        uint256 quotedOut = quote[1];

        bytes memory data = abi.encodeCall(
            IUniV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens,
            (0, path, user, block.timestamp + 600)
        );
        SwapParams memory p = SwapParams({
            inputToken: address(0),
            amountIn: inAmt,
            target: V2_ROUTER,
            data: data,
            outputToken: NOX,
            minOut: 0,
            receiver: user,
            routeId: keccak256("v2:eth-nox")
        });

        uint256 noxBefore = IERC20(NOX).balanceOf(user);
        uint256 treasuryBefore = treasurySafe.balance;

        vm.prank(user);
        router.swap{value: inAmt}(p);

        uint256 noxAfter = IERC20(NOX).balanceOf(user);
        uint256 fee = inAmt * 10 / 10000;

        assertEq(treasurySafe.balance - treasuryBefore, fee, "treasury 10 bps");
        assertGt(noxAfter, noxBefore, "user got NOX");
        assertGe(noxAfter - noxBefore, (quotedOut * 90) / 100, "post-FoT output near quote");
    }

    function test_fork_noxToEthOnRealUniswapV2() public {
        if (!_hasFork()) { vm.skip(true); return; }

        deal(NOX, user, 10000e18);

        vm.prank(user);
        IERC20(NOX).approve(address(router), 10000e18);

        address[] memory path = new address[](2);
        path[0] = NOX; path[1] = WETH;

        bytes memory data = abi.encodeCall(
            IUniV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens,
            (uint256(9990e18), uint256(0), path, user, block.timestamp + 600)
        );
        SwapParams memory p = SwapParams({
            inputToken: NOX,
            amountIn: 10000e18,
            target: V2_ROUTER,
            data: data,
            outputToken: address(0),
            minOut: 0,
            receiver: user,
            routeId: keccak256("v2:nox-eth")
        });

        uint256 ethBefore = user.balance;
        uint256 treasuryNoxBefore = IERC20(NOX).balanceOf(treasurySafe);

        vm.prank(user);
        router.swap(p);

        uint256 ethAfter = user.balance;
        uint256 noxFee = IERC20(NOX).balanceOf(treasurySafe) - treasuryNoxBefore;

        assertGt(ethAfter, ethBefore, "user received ETH");
        assertGt(noxFee, 0, "treasury received NOX fee");
        assertEq(IERC20(NOX).allowance(address(router), V2_ROUTER), 0, "allowance reset");
    }
}
