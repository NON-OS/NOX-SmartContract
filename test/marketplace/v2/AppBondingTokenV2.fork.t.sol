// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AppBondingTokenV2}              from "../../../contracts/marketplace/core/AppBondingTokenV2.sol";
import {IAppBondingTokenV2}             from "../../../contracts/marketplace/interfaces/IAppBondingTokenV2.sol";
import {IUniswapV2Factory, IUniswapV2Pair} from "../../../contracts/marketplace/interfaces/IUniswapV2.sol";
import {BondingCurveLib}                from "../../../contracts/marketplace/libraries/BondingCurveLib.sol";
import {MockFeeRouter}                  from "./Mocks.sol";

contract AppBondingTokenV2ForkTest is Test {
    address constant UNI_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNI_V2_ROUTER  = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH           = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LP_BURN        = address(0x000000000000000000000000000000000000dEaD);

    AppBondingTokenV2 token;
    MockFeeRouter feeRouter;
    address publisher = address(0xB2);
    address buyer     = address(0xD4);

    uint256 constant GRAD_SUPPLY    = 800_000 * 1e18;
    uint256 constant LP_RESERVE_CAP = 200_000_000 * 1e18;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        feeRouter = new MockFeeRouter();
        AppBondingTokenV2 impl = new AppBondingTokenV2();

        IAppBondingTokenV2.GraduationConfig memory cfg = IAppBondingTokenV2.GraduationConfig({
            graduationSupply: GRAD_SUPPLY,
            lpReserveCap:     LP_RESERVE_CAP,
            tradingFeeBps:    100,
            graduationFeeBps: 100,
            weth:             WETH,
            uniV2Factory:     UNI_V2_FACTORY,
            uniV2Router:      UNI_V2_ROUTER,
            lpBurnTo:         LP_BURN
        });

        IAppBondingTokenV2.AppLink memory link = IAppBondingTokenV2.AppLink({
            capsuleId:    keccak256("cap:fork-test"),
            releaseId:    keccak256("rel:fork"),
            manifestHash: keccak256("man:fork"),
            packageHash:  keccak256("pkg:fork"),
            publisher:    publisher
        });

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AppBondingTokenV2.initialize,
                (link, address(feeRouter), "ForkApp", "FORK", "ipfs://x", cfg))
        );
        token = AppBondingTokenV2(payable(address(proxy)));

        vm.deal(buyer, 5_000 ether);
    }

    function _has() internal view returns (bool) { return address(token) != address(0); }

    function _fillToGraduation() internal {
        uint256 reserveAtGrad = BondingCurveLib.reserveAtSupply(GRAD_SUPPLY);
        uint256 ethIn = reserveAtGrad * 10_000 / 9900 + 1;
        vm.prank(buyer);
        token.buy{value: ethIn}(0);
        if (token.totalSupply() < GRAD_SUPPLY) {
            vm.prank(buyer);
            token.buy{value: 0.5 ether}(0);
        }
    }

    function test_fork_graduateRealUniswapV2() public {
        if (!_has()) { vm.skip(true); return; }
        _fillToGraduation();

        uint256 reserveBefore = token.reserveBalance();
        assertGt(reserveBefore, 0, "reserve should be positive pre-grad");

        token.graduate();

        assertTrue(token.isGraduated());
        assertEq(token.reserveBalance(), 0, "reserve drained");
        assertEq(address(token).balance, 0, "no stuck eth");
        assertEq(token.balanceOf(address(token)), 0, "no stuck tokens");

        address pair = IUniswapV2Factory(UNI_V2_FACTORY).getPair(address(token), WETH);
        assertEq(pair, token.pair(), "factory and token agree on pair");
        assertTrue(pair != address(0), "real pair created");

        uint256 lpAtBurn = IERC20(pair).balanceOf(LP_BURN);
        assertGt(lpAtBurn, 0, "LP burned at 0xdead");

        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        uint256 tokR; uint256 ethR;
        if (t0 == address(token)) { tokR = r0; ethR = r1; }
        else                      { tokR = r1; ethR = r0; }
        assertGt(tokR, 0);
        assertGt(ethR, 0);

        uint256 spotPerToken = (ethR * 1e18) / tokR;
        uint256 terminalPrice = token.terminalPriceWeiPerToken();
        assertApproxEqAbs(spotPerToken, terminalPrice, 1, "price continuity");
    }

    function test_fork_graduate_idempotentOnLiveUniswap() public {
        if (!_has()) { vm.skip(true); return; }
        _fillToGraduation();
        token.graduate();
        vm.expectRevert(AppBondingTokenV2.AlreadyGraduated.selector);
        token.graduate();
    }

    function test_fork_buySellAfterGraduateRevert() public {
        if (!_has()) { vm.skip(true); return; }
        _fillToGraduation();
        token.graduate();
        vm.expectRevert(AppBondingTokenV2.AlreadyGraduated.selector);
        vm.prank(buyer);
        token.buy{value: 1 ether}(0);
    }
}
