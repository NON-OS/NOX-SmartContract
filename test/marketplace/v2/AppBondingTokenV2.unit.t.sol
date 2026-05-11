// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AppBondingTokenV2}     from "../../../contracts/marketplace/core/AppBondingTokenV2.sol";
import {IAppBondingTokenV2}    from "../../../contracts/marketplace/interfaces/IAppBondingTokenV2.sol";
import {BondingCurveLib}       from "../../../contracts/marketplace/libraries/BondingCurveLib.sol";
import {MockFeeRouter, MockUniV2Factory, MockUniV2Router, MockPair} from "./Mocks.sol";
import {MockERC20}             from "../../mocks/MockERC20.sol";

contract AppBondingTokenV2UnitTest is Test {
    AppBondingTokenV2 token;
    MockFeeRouter     feeRouter;
    MockUniV2Factory  uniFactory;
    MockUniV2Router   uniRouter;
    MockERC20         wethToken;
    address           weth;

    address publisher = address(0xB2);
    address buyer     = address(0xD4);
    address admin     = address(0xA1);
    address constant LP_BURN = address(0x000000000000000000000000000000000000dEaD);

    uint256 constant GRAD_SUPPLY = 800_000 * 1e18;
    uint256 constant LP_RESERVE_CAP = 100_000_000 * 1e18;

    function _config() internal view returns (IAppBondingTokenV2.GraduationConfig memory) {
        return IAppBondingTokenV2.GraduationConfig({
            graduationSupply: GRAD_SUPPLY,
            lpReserveCap:     LP_RESERVE_CAP,
            tradingFeeBps:    100,
            graduationFeeBps: 100,
            weth:             weth,
            uniV2Factory:     address(uniFactory),
            uniV2Router:      address(uniRouter),
            lpBurnTo:         LP_BURN
        });
    }

    function _link() internal pure returns (IAppBondingTokenV2.AppLink memory) {
        return IAppBondingTokenV2.AppLink({
            capsuleId:    keccak256("cap:test"),
            releaseId:    keccak256("rel:1"),
            manifestHash: keccak256("man:1"),
            packageHash:  keccak256("pkg:1"),
            publisher:    address(0xB2)
        });
    }

    AppBondingTokenV2 _impl;

    function _deploy(IAppBondingTokenV2.GraduationConfig memory cfg) internal returns (AppBondingTokenV2 t) {
        if (address(_impl) == address(0)) _impl = new AppBondingTokenV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(_impl),
            abi.encodeCall(AppBondingTokenV2.initialize,
                (_link(), address(feeRouter), "App", "APP", "ipfs://x", cfg))
        );
        t = AppBondingTokenV2(payable(address(proxy)));
    }

    function setUp() public {
        wethToken  = new MockERC20("WETH","WETH");
        weth       = address(wethToken);
        feeRouter  = new MockFeeRouter();
        uniFactory = new MockUniV2Factory();
        uniRouter  = new MockUniV2Router(address(uniFactory), weth);
        _impl = new AppBondingTokenV2();
        vm.deal(buyer, 1000 ether);
        token = _deploy(_config());
    }

    function test_init_revertsOnZeroLpCap() public {
        IAppBondingTokenV2.GraduationConfig memory cfg = _config();
        cfg.lpReserveCap = 0;
        vm.expectRevert(IAppBondingTokenV2.LpReserveCapZero.selector);
        _deploy(cfg);
    }

    function test_init_revertsOnGraduationFeeAboveCap() public {
        IAppBondingTokenV2.GraduationConfig memory cfg = _config();
        cfg.graduationFeeBps = 101;
        vm.expectRevert(abi.encodeWithSelector(IAppBondingTokenV2.GraduationFeeTooHigh.selector, uint16(100), uint16(101)));
        _deploy(cfg);
    }

    function test_init_revertsIfLpCapBelowMaxRequired() public {
        IAppBondingTokenV2.GraduationConfig memory cfg = _config();
        cfg.lpReserveCap = 1;
        vm.expectRevert();
        _deploy(cfg);
    }

    function test_init_revertsOnZeroAddresses() public {
        IAppBondingTokenV2.GraduationConfig memory cfg = _config();
        cfg.weth = address(0);
        vm.expectRevert(IAppBondingTokenV2.InvalidUniswapAddresses.selector);
        _deploy(cfg);
    }

    function test_buy_succeedsAndBumpsSupply() public {
        vm.prank(buyer);
        uint256 out = token.buy{value: 0.1 ether}(0);
        assertGt(out, 0);
        assertEq(token.balanceOf(buyer), out);
        assertGt(token.reserveBalance(), 0);
    }

    function test_sell_succeeds() public {
        vm.prank(buyer);
        uint256 boughtTokens = token.buy{value: 0.1 ether}(0);
        vm.prank(buyer);
        uint256 ethOut = token.sell(boughtTokens / 2, 0);
        assertGt(ethOut, 0);
    }

    function test_buy_revertsAfterGraduated() public {
        _fillToGraduation();
        token.graduate();
        vm.expectRevert(AppBondingTokenV2.AlreadyGraduated.selector);
        vm.prank(buyer);
        token.buy{value: 1 ether}(0);
    }

    function test_sell_revertsAfterGraduated() public {
        _fillToGraduation();
        token.graduate();
        vm.expectRevert(AppBondingTokenV2.AlreadyGraduated.selector);
        vm.prank(buyer);
        token.sell(1e18, 0);
    }

    function test_graduate_revertsBeforeThreshold() public {
        vm.expectRevert(AppBondingTokenV2.NotGraduatedYet.selector);
        token.graduate();
    }

    function test_graduate_succeedsAndCreatesPair() public {
        _fillToGraduation();

        uint256 reserveBefore = token.reserveBalance();
        assertGt(reserveBefore, 0);

        token.graduate();

        assertTrue(token.isGraduated(), "should be graduated");
        assertEq(token.reserveBalance(), 0, "reserve must be drained");
        assertEq(address(token).balance, 0, "no stuck eth");
        assertEq(token.balanceOf(address(token)), 0, "no stuck tokens");
        assertTrue(token.pair() != address(0), "pair was created");
    }

    function test_graduate_takesGraduationFee() public {
        _fillToGraduation();
        uint256 reserveBefore = token.reserveBalance();
        uint256 expectedFee = reserveBefore * 100 / 10_000;
        uint256 routedBefore = feeRouter.totalRouted();

        token.graduate();

        assertEq(feeRouter.totalRouted() - routedBefore, expectedFee, "graduation fee routed");
    }

    function test_graduate_idempotent() public {
        _fillToGraduation();
        token.graduate();
        vm.expectRevert(AppBondingTokenV2.AlreadyGraduated.selector);
        token.graduate();
    }

    function test_graduate_pricesPairAtTerminalCurvePrice() public {
        _fillToGraduation();
        uint256 terminalPrice = token.terminalPriceWeiPerToken();

        token.graduate();

        address pair = token.pair();
        (uint112 r0, uint112 r1, ) = MockPair(pair).getReserves();
        uint256 ethR;
        uint256 tokR;
        if (MockPair(pair).token0() == address(token)) {
            tokR = r0; ethR = r1;
        } else {
            tokR = r1; ethR = r0;
        }
        uint256 spotPerToken = (uint256(ethR) * 1e18) / uint256(tokR);
        assertApproxEqAbs(spotPerToken, terminalPrice, 1);
    }

    function test_graduate_pairAlreadySeededReverts() public {
        _fillToGraduation();
        address fakePair = address(uniFactory.createPair(address(token), weth));
        MockPair(fakePair).setReserves(123, 456);
        vm.expectRevert(abi.encodeWithSelector(IAppBondingTokenV2.PairAlreadySeeded.selector, uint112(123), uint112(456)));
        token.graduate();
    }

    function test_graduate_pairExistsButZeroReservesIsAccepted() public {
        _fillToGraduation();
        uniFactory.createPair(address(token), weth);
        token.graduate();
        assertTrue(token.isGraduated());
    }

    function test_graduate_pairDonationAttackBlocked_tokenBalance() public {
        _fillToGraduation();
        address fakePair = uniFactory.createPair(address(token), weth);
        deal(address(token), fakePair, 12345);
        vm.expectRevert();
        token.graduate();
    }

    function test_graduate_pairDonationAttackBlocked_wethBalance() public {
        _fillToGraduation();
        address fakePair = uniFactory.createPair(address(token), weth);
        deal(weth, fakePair, 7777);
        vm.expectRevert();
        token.graduate();
    }

    function test_graduate_blockedWhenPaused() public {
        _fillToGraduation();
        vm.prank(publisher);
        token.pauseTrading();
        vm.expectRevert();
        token.graduate();
    }

    function test_graduate_revertsIfRouterReturnsWrongAmounts() public {
        _fillToGraduation();
        uniRouter.setDust(1, 1);
        vm.expectRevert();
        token.graduate();
    }

    function test_views_consistent() public view {
        assertGt(token.terminalPriceWeiPerToken(), 0);
        assertGt(token.maxTokensToLp(), 0);
    }

    function _fillToGraduation() internal {
        uint256 reserveAtGrad = BondingCurveLib.reserveAtSupply(GRAD_SUPPLY);
        uint256 ethIn = reserveAtGrad * 10_000 / (10_000 - 100) + 1;
        vm.deal(buyer, ethIn + 1 ether);
        vm.prank(buyer);
        token.buy{value: ethIn}(0);
        if (token.totalSupply() < GRAD_SUPPLY) {
            vm.prank(buyer);
            token.buy{value: 0.5 ether}(0);
        }
    }
}
